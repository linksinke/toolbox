# -*- coding: utf-8 -*-
"""MySQL 表结构导出工具入口。用法：python main.py -h"""

from __future__ import absolute_import, division, print_function, unicode_literals

# 尽早修复 Py2 + cp65001，并挂载离线依赖（须在 import cli / argparse -h 之前）
from core.support import fix_stdio, setup_vendor

fix_stdio()
setup_vendor()

from core.cli import main

if __name__ == "__main__":
    main()
