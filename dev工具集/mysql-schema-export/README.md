# MySQL 表结构导出工具

从指定 MySQL 库导出表结构（`CREATE TABLE`）为 SQL 文件，便于备份、迁移、对照分表结构。

兼容 **Python 2.7** / **Python 3**，并内置离线依赖，拷贝目录后一般无需 `pip install`。

## 能做什么

- 按 `conf.yml` 连接源库，导出全部表或指定表的 DDL
- 输出可执行的 SQL（可选库头、`DROP TABLE`、外键检查开关等）

## 快速开始

```bash
# 1. 修改 conf.yml 里的 source_db
# 2. 在本目录执行
python main.py
```

默认输出：`output/schema.sql`。

## 常用命令

```bash
python main.py                              # 按 conf.yml 导出
python main.py -c conf.yml                  # 指定配置文件
python main.py -t users orders              # 只导出指定表
python main.py -o output/otb_ddd.sql        # 指定输出文件
python main.py --list-tables                # 列出源库表名
python main.py --include-drop               # 每张表前加 DROP TABLE IF EXISTS
python main.py -h                           # 帮助
```

## 配置说明（conf.yml）

```yaml
source_db:
  host: 127.0.0.1
  port: 3306
  user: root
  password: '***'
  database: your_db
  charset: utf8mb4          # 可选

export:
  output: output/schema.sql # 输出路径（相对 conf.yml 所在目录）
  tables: []                # 空=全部表；也可写表名列表
  include_drop: false       # 是否加 DROP TABLE IF EXISTS
  include_header: true      # 是否写文件头 / USE / FOREIGN_KEY_CHECKS
  log_level: INFO
```

## 目录结构

```text
分表的结构/
  main.py                 # 入口
  conf.yml                # 数据源与导出选项
  README.md               # 本说明
  requirements.txt        # 可选：不用 vendor 时的 pip 依赖
  core/
    support.py            # 离线依赖加载、Py2/Py3 兼容、日志
    exporter.py           # 配置、连库、DDL 导出
    cli.py                # 命令行
    prepare_vendor.py     # 联网准备离线依赖（维护用）
  vendor/
    python2/              # Python 2.7 离线包（pymysql、yaml）
    python3/              # Python 3 离线包（pymysql、yaml）
  output/                 # 导出结果（默认不提交）
```

## 离线依赖说明

程序启动时会按当前解释器自动选择：


| 运行环境       | 使用目录              |
| ---------- | ----------------- |
| Python 2.x | `vendor/python2/` |
| Python 3.x | `vendor/python3/` |


强制指定（调试）：

```bat
set SCHEMA_EXPORT_VENDOR=python2
python main.py
```

更新离线包（需联网，建议用 Python 3）：

```bash
python core/prepare_vendor.py
```

若不用内置 vendor，也可自行安装：

```bash
pip install -r requirements.txt
```

## 注意

- 本工具只导出**表结构**，不导出数据
- 不包含视图、触发器、存储过程等对象
- `SHOW CREATE TABLE` 可能带出 `AUTO_INCREMENT` 当前值，迁移空库时如需干净 schema 请自行去掉

