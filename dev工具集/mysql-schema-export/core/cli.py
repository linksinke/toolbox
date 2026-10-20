# -*- coding: utf-8 -*-
"""命令行入口：参数解析、子命令调度、退出码约定。

由项目根目录 main.py 调用：
  from core.cli import main
  main()

退出码：0 成功，1 业务/运行错误。
"""

from __future__ import absolute_import, division, print_function, unicode_literals

import argparse
import logging
import os
import sys

from .exporter import AppConfig, SchemaExporter
from .support import (
    FileNotFoundError,
    abspath,
    ensure_text,
    path_join,
    safe_print,
    setup_logging,
    setup_vendor,
    to_fs,
)

# 确保离线依赖已就绪（main.py 通常已调用过，此处幂等）
setup_vendor()

# 追加到 -h 帮助末尾的用法说明
USAGE = """
mysql-schema-export — MySQL 表结构（CREATE TABLE）导出工具
兼容 Python 2.7 / Python 3；仅支持 MySQL。

用法：
  python main.py                              # 按 conf.yml 导出全部表结构
  python main.py -c conf.yml                  # 指定配置文件
  python main.py -t users orders              # 只导出指定表
  python main.py -o output/mydb.sql           # 指定输出文件
  python main.py --list-tables                # 列出源库所有表
  python main.py --include-drop               # 每张表前加 DROP TABLE IF EXISTS
"""


def parse_args(argv=None):
    """解析命令行参数；argv 为 None 时使用 sys.argv。"""
    parser = argparse.ArgumentParser(
        prog="mysql-schema-export",
        description="从 MySQL 源库导出表结构（CREATE TABLE）SQL；仅支持 MySQL。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=USAGE,
    )
    parser.add_argument("-c", "--config", default="conf.yml", metavar="FILE", help="配置文件路径")
    parser.add_argument("-t", "--tables", nargs="*", metavar="TABLE", help="只导出指定表")
    parser.add_argument("-o", "--output", default="", metavar="FILE", help="输出 SQL 文件路径")
    parser.add_argument("--list-tables", action="store_true", help="仅列出源库表名")
    parser.add_argument("--include-drop", action="store_true", help="追加 DROP TABLE IF EXISTS")
    parser.add_argument("--log-level", default="", metavar="LEVEL", help="日志级别")
    return parser.parse_args(argv)


def run(argv=None):
    """执行一次完整 CLI 流程，返回进程退出码（0/1）。"""
    args = parse_args(argv)

    # 相对路径按「当前工作目录」解析，再转为绝对路径
    config_path = to_fs(args.config)
    if not os.path.isabs(config_path):
        config_path = path_join(os.getcwd(), config_path)
    config_path = abspath(config_path)

    try:
        config = AppConfig.load(config_path)
        # CLI 开关可覆盖配置文件中的 include_drop
        if args.include_drop:
            config.export.include_drop = True

        setup_logging(args.log_level or config.export.log_level)
        exporter = SchemaExporter(config)
        src = config.source_db
        logging.info("源库：%s@%s:%s/%s", src.user, src.host, src.port, src.database)

        if args.list_tables:
            # 仅列表，不写文件
            tables = exporter.list_source_tables()
            safe_print("\n源库 `{0}` 共 {1} 张表：\n".format(src.database, len(tables)))
            for name in tables:
                safe_print("  - {0}".format(name))
            safe_print("")
        else:
            path = exporter.export(config.resolve_output(args.output), args.tables or None)
            safe_print("表结构已导出：{0}".format(path))
        return 0
    except (FileNotFoundError, ValueError, RuntimeError) as e:
        # 预期内的配置/业务错误：简短提示
        safe_print("[ERROR] {0}".format(ensure_text(e)))
        return 1
    except Exception as e:
        # 未预期异常：打完整堆栈便于排查
        logging.exception("导出失败：%s", e)
        return 1


def main(argv=None):
    """进程入口：执行 run 并以退出码结束进程。"""
    sys.exit(run(argv))
