# -*- coding: utf-8 -*-
"""导出业务层：配置、MySQL 访问、DDL 文本组装与导出编排。

仅面向 MySQL（通过 PyMySQL 连接）。流程概览：
  AppConfig.load(conf.yml)
    -> SchemaExporter.build_ddl()
         -> list_tables / fetch_create_table
         -> DdlFormatter 拼成 SQL 文本
    -> 写入输出文件
"""

from __future__ import absolute_import, division, print_function, unicode_literals

import logging
from contextlib import contextmanager
from datetime import datetime

from .support import setup_vendor

# 导入第三方库前先挂载 vendor
setup_vendor()

import pymysql  # noqa: E402
import yaml  # noqa: E402
from pymysql.cursors import DictCursor  # noqa: E402

from .support import (  # noqa: E402
    FileNotFoundError,
    abspath,
    ensure_text,
    is_abs,
    norm_path,
    path_dirname,
    path_exists,
    path_join,
    read_text,
    string_types,
    write_text,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# 配置（对应 conf.yml）
# ---------------------------------------------------------------------------

class DbConfig(object):
    """MySQL 源库连接配置（conf.yml 的 source_db 段）。"""

    def __init__(self, host, port=3306, user="root", password="", database="", charset="utf8mb4"):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.charset = charset

    @classmethod
    def from_dict(cls, data):
        """从 YAML 字典构造；校验 host / user / database 必填。"""
        if not data:
            raise ValueError("缺少 source_db 配置")
        required = ("host", "user", "database")
        missing = [k for k in required if not data.get(k)]
        if missing:
            raise ValueError("source_db 缺少必填项：{0}".format(", ".join(missing)))
        return cls(
            host=ensure_text(data["host"]),
            port=int(data.get("port", 3306)),
            user=ensure_text(data["user"]),
            password="" if data.get("password") is None else ensure_text(data["password"]),
            database=ensure_text(data["database"]),
            charset=ensure_text(data.get("charset", "utf8mb4")),
        )


class ExportOptions(object):
    """导出行为选项（conf.yml 的 export 段）。"""

    def __init__(
        self,
        output="output/schema.sql",
        tables=None,
        include_drop=False,
        include_header=True,
        log_level="INFO",
    ):
        self.output = output              # 输出 SQL 路径
        self.tables = list(tables or [])  # 空列表表示导出全部表
        self.include_drop = include_drop  # 是否加 DROP TABLE IF EXISTS
        self.include_header = include_header  # 是否写文件头 / USE / FK 开关
        self.log_level = log_level

    @classmethod
    def from_dict(cls, data):
        """从 YAML 字典构造；tables 支持列表或逗号分隔字符串。"""
        data = data or {}
        tables = data.get("tables") or []
        if isinstance(tables, string_types):
            tables = [t.strip() for t in tables.split(",") if t.strip()]
        return cls(
            output=ensure_text(data.get("output", "output/schema.sql")),
            tables=list(tables),
            include_drop=bool(data.get("include_drop", False)),
            include_header=bool(data.get("include_header", True)),
            log_level=ensure_text(data.get("log_level", "INFO")),
        )


class AppConfig(object):
    """完整应用配置：源库 + 导出选项 + 配置文件所在目录。"""

    def __init__(self, source_db, export, base_dir):
        self.source_db = source_db  # DbConfig
        self.export = export        # ExportOptions
        self.base_dir = base_dir    # conf.yml 所在目录，用于解析相对输出路径

    @classmethod
    def load(cls, config_path):
        """从 YAML 文件加载配置。"""
        path = abspath(ensure_text(config_path))
        if not path_exists(path):
            raise FileNotFoundError("配置文件不存在：{0}".format(path))

        raw = yaml.safe_load(read_text(path)) or {}
        if not isinstance(raw, dict):
            raise ValueError("配置文件内容必须是 YAML 对象")

        return cls(
            source_db=DbConfig.from_dict(raw.get("source_db") or {}),
            export=ExportOptions.from_dict(raw.get("export")),
            base_dir=path_dirname(path),
        )

    def resolve_output(self, override=""):
        """解析最终输出路径；override 非空时覆盖配置中的 export.output。"""
        rel = ensure_text(override or self.export.output)
        if is_abs(rel):
            return norm_path(rel)
        return path_join(self.base_dir, rel)


# ---------------------------------------------------------------------------
# 数据库访问（MySQL / PyMySQL）
# ---------------------------------------------------------------------------

def connect(cfg):
    """按 DbConfig 建立 MySQL 连接。"""
    return pymysql.connect(
        host=cfg.host,
        port=cfg.port,
        user=cfg.user,
        password=cfg.password,
        database=cfg.database,
        charset=cfg.charset,
        autocommit=True,
        cursorclass=DictCursor,
        connect_timeout=30,
    )


@contextmanager
def db_session(cfg):
    """连接上下文：退出时自动 close。"""
    conn = connect(cfg)
    try:
        yield conn
    finally:
        conn.close()


def list_tables(conn):
    """列出当前库中的表名（SHOW TABLES）。"""
    with conn.cursor() as cur:
        cur.execute("SHOW TABLES;")
        return [ensure_text(list(row.values())[0]) for row in cur.fetchall()]


def fetch_create_table(conn, table):
    """获取单表 CREATE TABLE 语句（SHOW CREATE TABLE）。"""
    table = ensure_text(table)
    with conn.cursor() as cur:
        # 表名中的反引号按 MySQL 规则转义为两个反引号
        cur.execute("SHOW CREATE TABLE `{0}`;".format(table.replace("`", "``")))
        row = cur.fetchone()
        if not row or "Create Table" not in row:
            raise RuntimeError("无法获取表结构：{0}".format(table))
        return ensure_text(row["Create Table"])


# ---------------------------------------------------------------------------
# DDL 文本组装
# ---------------------------------------------------------------------------

class DdlFormatter(object):
    """把库名、表名、CREATE TABLE 拼成可执行的 SQL 文本。"""

    def __init__(self, include_drop=False, include_header=True):
        self.include_drop = include_drop
        self.include_header = include_header

    def header(self, database, table_count):
        """文件头：元信息注释 + CREATE DATABASE + USE + 关闭外键检查。"""
        if not self.include_header:
            return ""
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        database = ensure_text(database)
        return "\n".join(
            [
                "-- ============================================================",
                "-- mysql-schema-export (MySQL DDL)",
                "-- 数据库：{0}".format(database),
                "-- 表数量：{0}".format(table_count),
                "-- 导出时间：{0}".format(now),
                "-- ============================================================",
                "",
                "CREATE DATABASE IF NOT EXISTS `{0}` DEFAULT CHARACTER SET utf8mb4;".format(
                    database
                ),
                "USE `{0}`;".format(database),
                "SET NAMES utf8mb4;",
                "SET FOREIGN_KEY_CHECKS = 0;",
                "",
            ]
        )

    def table_block(self, table, ddl):
        """单表块：注释 + 可选 DROP + CREATE TABLE。"""
        table = ensure_text(table)
        lines = [
            "-- ------------------------------------------------------------",
            "-- Table structure for `{0}`".format(table),
            "-- ------------------------------------------------------------",
        ]
        if self.include_drop:
            lines.append("DROP TABLE IF EXISTS `{0}`;".format(table))
        lines.append(ensure_text(ddl).rstrip(";") + ";")
        lines.append("")
        return "\n".join(lines)

    def footer(self):
        """文件尾：恢复外键检查（与 header 成对）。"""
        if not self.include_header:
            return ""
        return "SET FOREIGN_KEY_CHECKS = 1;\n"


# ---------------------------------------------------------------------------
# 导出编排
# ---------------------------------------------------------------------------

class SchemaExporter(object):
    """从 MySQL 源库导出表结构 DDL 的编排入口。"""

    def __init__(self, config):
        """config: AppConfig 实例。"""
        self.config = config
        self.formatter = DdlFormatter(
            include_drop=config.export.include_drop,
            include_header=config.export.include_header,
        )

    def list_source_tables(self):
        """列出源库全部表名（独立短连接）。"""
        with db_session(self.config.source_db) as conn:
            return list_tables(conn)

    def _filter_tables(self, all_tables, tables=None):
        """按 CLI / 配置过滤目标表；不存在的表名打 warning 后跳过。"""
        wanted = list(tables) if tables else list(self.config.export.tables)
        if not wanted:
            return list(all_tables)
        all_set = set(all_tables)
        missing = [t for t in wanted if t not in all_set]
        if missing:
            logger.warning("以下表在源库中不存在，将跳过：%s", ", ".join(missing))
        return [t for t in wanted if t in all_set]

    def build_ddl(self, tables=None):
        """生成完整 DDL 文本。

        列表与 SHOW CREATE TABLE 共用同一连接，避免连两次库。
        tables 为 None 时使用配置中的 export.tables（空则全部）。
        """
        src = self.config.source_db
        blocks = []
        with db_session(src) as conn:
            target_tables = self._filter_tables(list_tables(conn), tables)
            if not target_tables:
                raise RuntimeError("没有可导出的表")

            header = self.formatter.header(src.database, len(target_tables))
            if header:
                blocks.append(header)

            for idx, table in enumerate(target_tables, 1):
                logger.info("[%d/%d] 导出表结构：%s", idx, len(target_tables), table)
                ddl = fetch_create_table(conn, table)
                blocks.append(self.formatter.table_block(table, ddl))

            footer = self.formatter.footer()
            if footer:
                blocks.append(footer)

        return "\n".join(blocks).rstrip() + "\n"

    def export(self, output, tables=None):
        """生成 DDL 并写入文件，返回输出路径（文本形式）。"""
        output = norm_path(output)
        write_text(output, self.build_ddl(tables))
        output_text = ensure_text(output)
        logger.info("DDL 已写入：%s", output_text)
        return output_text

