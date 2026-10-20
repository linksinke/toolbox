离线 Python 依赖（按解释器分开，互不共用）

  vendor/python2/   -> 仅给 Python 2.7 使用
  vendor/python3/   -> 仅给 Python 3 使用

启动时会按当前 python 版本自动选择：
  Python 2.x  => vendor/python2
  Python 3.x  => vendor/python3

也可强制指定（调试用）：
  set SCHEMA_EXPORT_VENDOR=python2
  set SCHEMA_EXPORT_VENDOR=python3

更新离线包（需联网，建议 Python 3）：
  python core/prepare_vendor.py
