# -*- coding: utf-8 -*-
"""
mysql-schema-export 核心包（仅支持 MySQL）。

模块说明：
  support.py         离线 vendor 加载、Py2/Py3 兼容、控制台与日志
  exporter.py        配置解析、MySQL 访问、DDL 组装与导出编排
  cli.py             命令行参数解析与子命令入口
  prepare_vendor.py  联网下载并生成 vendor/python2|python3（维护用）

对外导出：
  SchemaExporter  — 供其它 Python 代码直接调用导出能力
"""

from __future__ import absolute_import, division, print_function, unicode_literals

from .support import setup_vendor

# 包导入时即挂载对应解释器的离线依赖，保证后续 import pymysql/yaml 可用
setup_vendor()

from .exporter import SchemaExporter

__all__ = ["SchemaExporter"]
