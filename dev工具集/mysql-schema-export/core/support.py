# -*- coding: utf-8 -*-
"""运行支撑层：离线依赖、Py2/Py3 兼容、控制台与日志。

职责：
  1. 按当前解释器把 vendor/python2 或 vendor/python3 插入 sys.path
  2. 统一文本 / 路径类型，避免 Windows 中文路径与 Py2 编码问题
  3. 提供可在 cp65001 控制台下安全工作的打印与 logging

注意：本文件故意不启用 unicode_literals，
否则 Py2 下 os.path.join 混用 str/unicode 可能触发 UnicodeDecodeError。
"""

from __future__ import absolute_import, division, print_function

import io
import logging
import os
import sys

# True 表示运行在 Python 2.x
PY2 = sys.version_info[0] == 2
# 文件系统默认编码（Windows 常见为 mbcs/gbk）
FS_ENC = sys.getfilesystemencoding() or ("mbcs" if os.name == "nt" else "utf-8")
# setup_vendor 是否已执行过（避免重复插入 sys.path）
_BOOTSTRAPPED = False
# 是否已修复过 stdout/stderr（Py2 + cp65001）
_STDIO_FIXED = False

# Py3 有内置 FileNotFoundError；Py2 用 IOError 兜底，便于统一 catch
try:
    FileNotFoundError = FileNotFoundError  # noqa: A001
except NameError:
    FileNotFoundError = IOError  # noqa: A001

# 字符串基类：Py2 为 basestring，Py3 为 str
try:
    string_types = (basestring,)  # noqa: F821
except NameError:
    string_types = (str,)


# ---------------------------------------------------------------------------
# 标准输出修复（Py2 + Windows UTF-8 控制台）
# ---------------------------------------------------------------------------

class _SafeTextStream(object):
    """包装 stdout/stderr，对外宣称 encoding=utf-8。

    Python 2.7 不认识 Windows 的 cp65001，argparse.print_help() /
    file.write(unicode) 会抛 LookupError。包装后统一按 utf-8 写出。
    """

    def __init__(self, stream):
        self._stream = stream
        self.encoding = "utf-8"
        self.errors = "replace"
        self.closed = getattr(stream, "closed", False)

    def write(self, data):
        if data is None:
            return
        if isinstance(data, unicode):  # noqa: F821
            data = data.encode(self.encoding, self.errors)
        return self._stream.write(data)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        return self._stream.flush()

    def fileno(self):
        return self._stream.fileno()

    def isatty(self):
        return self._stream.isatty()

    def __getattr__(self, name):
        return getattr(self._stream, name)


def _needs_stdio_fix(stream):
    """判断该流在 Py2 下写 unicode 是否会踩编码坑。"""
    if stream is None or isinstance(stream, _SafeTextStream):
        return False
    enc = getattr(stream, "encoding", None)
    if not enc:
        # encoding=None 时 write(unicode) 常按 ascii，中文帮助会崩
        return True
    key = enc.lower().replace("-", "")
    # cp65001：Py2 不认识；ascii：写中文必炸
    return key in ("cp65001", "65001", "ascii", "ansix341968")


def fix_stdio():
    """修复 Py2 标准输出，避免 argparse -h / 中文日志崩溃。

    覆盖场景：
      - Windows UTF-8 控制台 encoding=cp65001 -> LookupError
      - encoding=None / ascii -> UnicodeEncodeError

    必须在 argparse.print_help 之前调用。
    """
    global _STDIO_FIXED
    if _STDIO_FIXED or not PY2:
        return
    for name in ("stdout", "stderr"):
        stream = getattr(sys, name, None)
        if _needs_stdio_fix(stream):
            setattr(sys, name, _SafeTextStream(stream))
    _STDIO_FIXED = True


# ---------------------------------------------------------------------------
# 离线依赖（vendor）
# ---------------------------------------------------------------------------

def _normalize_vendor_name(name):
    """把环境变量取值规范成 python2 / python3；无法识别则返回空串。"""
    name = (name or "").strip().lower()
    if name in ("python2", "py2", "2"):
        return "python2"
    if name in ("python3", "py3", "3"):
        return "python3"
    return ""


def resolve_vendor_dir(vendor_root=None):
    """解析应加载的离线依赖目录。

    优先级：
      1. 环境变量 SCHEMA_EXPORT_VENDOR / MYSQL_SCHEMA_EXPORT_VENDOR
      2. 当前解释器主版本：2 -> vendor/python2，3 -> vendor/python3

    Returns:
      (绝对路径, 运行时名称) 例如 (\".../vendor/python3\", \"python3\")
    """
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    if vendor_root is None:
        vendor_root = os.path.join(root, "vendor")

    # 兼容新旧环境变量名
    forced = _normalize_vendor_name(
        os.environ.get("MYSQL_SCHEMA_EXPORT_VENDOR")
        or os.environ.get("SCHEMA_EXPORT_VENDOR", "")
    )
    chosen = forced or ("python2" if PY2 else "python3")
    return os.path.join(vendor_root, chosen), chosen


def setup_vendor():
    """将当前解释器对应的 vendor 目录插到 sys.path 最前。

    插入后即可 import 内置的 pymysql、yaml，无需系统 pip 安装。
    目录不存在时仅告警，不中断（仍可尝试使用系统 site-packages）。
    """
    global _BOOTSTRAPPED
    # 无论是否已 bootstrap，都先确保控制台编码可用（幂等）
    fix_stdio()
    if _BOOTSTRAPPED:
        return

    vendor_dir, chosen = resolve_vendor_dir()
    if not os.path.isdir(vendor_dir):
        sys.stderr.write(
            "[WARN] offline vendor missing: {0}\n"
            "      run: python core/prepare_vendor.py\n".format(vendor_dir)
        )
    elif vendor_dir not in sys.path:
        # 放在最前，避免被系统里不兼容版本抢先导入
        sys.path.insert(0, vendor_dir)

    setup_vendor._info = {
        "vendor_dir": vendor_dir,
        "runtime": chosen,
        "python": sys.version.split()[0],
    }
    _BOOTSTRAPPED = True


def get_vendor_info():
    """返回当前已加载的离线依赖信息（路径、runtime、Python 版本）。"""
    if not _BOOTSTRAPPED:
        setup_vendor()
    return getattr(setup_vendor, "_info", {})


# ---------------------------------------------------------------------------
# 文本 / 路径
# ---------------------------------------------------------------------------

def ensure_text(value):
    """转为文本类型：Py2 -> unicode，Py3 -> str。"""
    if value is None:
        return u""
    if PY2:
        if isinstance(value, unicode):  # noqa: F821
            return value
        if isinstance(value, str):
            try:
                return value.decode("utf-8")
            except UnicodeDecodeError:
                return value.decode(FS_ENC, "replace")
        return unicode(value)  # noqa: F821
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8")
        except UnicodeDecodeError:
            return value.decode(FS_ENC, "replace")
    return str(value)


def to_fs(path):
    """转为 os.path / open 可接受的本地路径类型。

    Py2 + Windows 中文路径下，unicode 路径需按 FS_ENC 编码成 str，
    否则 path join / open 可能失败。
    """
    if path is None:
        return path
    if PY2:
        if isinstance(path, unicode):  # noqa: F821
            return path.encode(FS_ENC)
        return path
    if isinstance(path, bytes):
        return path.decode(FS_ENC)
    return path


def norm_path(path):
    """统一路径分隔符并做 normpath。

    配置里常写 output/schema.sql（正斜杠），Windows 上 join 后会出现
    D:\\proj\\output/schema.sql 这种混用，这里统一成系统分隔符。
    """
    path = to_fs(path)
    if not path:
        return path
    # 先把 / 换成 os.sep，再交给 normpath 处理 . / .. 等
    if os.sep != "/":
        path = path.replace("/", os.sep)
    return os.path.normpath(path)


def ensure_dir(path):
    """递归创建目录（兼容无 exist_ok 的 Python 2）。"""
    path = norm_path(path)
    if path and not os.path.isdir(path):
        os.makedirs(path)


def read_text(path):
    """以 UTF-8 读取文本文件。"""
    with io.open(norm_path(path), "r", encoding="utf-8") as f:
        return f.read()


def write_text(path, content):
    """以 UTF-8 写入文本文件；自动创建父目录。"""
    path = norm_path(path)
    parent = os.path.dirname(path)
    if parent:
        ensure_dir(parent)
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(ensure_text(content))


def abspath(path):
    """展开 ~ 并转为绝对路径（分隔符已规范化）。"""
    return norm_path(os.path.abspath(os.path.expanduser(to_fs(path))))


def is_abs(path):
    """判断是否为绝对路径。"""
    return os.path.isabs(norm_path(path))


def path_join(*parts):
    """路径拼接，并规范化分隔符（避免 Win 下 \\ 与 / 混用）。"""
    return norm_path(os.path.join(*[to_fs(p) for p in parts]))


def path_dirname(path):
    """返回路径所在目录。"""
    return os.path.dirname(norm_path(path))


def path_exists(path):
    """判断路径是否存在。"""
    return os.path.exists(norm_path(path))


# ---------------------------------------------------------------------------
# 控制台 / 日志
# ---------------------------------------------------------------------------

def console_encoding(stream=None):
    """解析控制台编码。

    Windows 开启 UTF-8 控制台时 encoding 常为 cp65001，
    但 Python 2.7 不认识该名，需映射为 utf-8。
    """
    stream = stream or sys.stdout
    enc = getattr(stream, "encoding", None) or FS_ENC or "utf-8"
    key = ensure_text(enc).lower().replace("-", "")
    if key in ("cp65001", "65001"):
        return "utf-8"
    return enc


class SafeStreamHandler(logging.StreamHandler):
    """兼容 Py2 + Windows UTF-8 控制台的日志 Handler。

    标准 logging 在 encoding=cp65001 时可能抛 LookupError，
    本 Handler 自行按 console_encoding() 编码后写出。
    """

    def emit(self, record):
        try:
            msg = self.format(record)
            stream = self.stream
            if PY2:
                if isinstance(msg, unicode):  # noqa: F821
                    data = msg.encode(console_encoding(stream), "replace")
                else:
                    data = msg
                stream.write(data)
                stream.write(b"\n")
            else:
                stream.write(msg + self.terminator)
            self.flush()
        except Exception:
            self.handleError(record)


def safe_print(msg):
    """安全打印到 stdout，避免中文路径在 Py2 控制台崩溃。"""
    text = ensure_text(msg)
    encoding = console_encoding(sys.stdout)
    if PY2:
        sys.stdout.write(text.encode(encoding, "replace") + b"\n")
    else:
        try:
            print(text)
        except UnicodeEncodeError:
            sys.stdout.buffer.write(text.encode(encoding, "replace") + b"\n")


def setup_logging(level):
    """初始化根日志：清空旧 Handler，挂上 SafeStreamHandler。"""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            try:
                reconfigure(encoding="utf-8")
            except Exception:
                pass

    root = logging.getLogger()
    for handler in list(root.handlers):
        root.removeHandler(handler)

    handler = SafeStreamHandler(sys.stdout)
    handler.setFormatter(
        logging.Formatter(
            "%(asctime)s  %(levelname)-8s  %(message)s",
            "%Y-%m-%d %H:%M:%S",
        )
    )
    root.addHandler(handler)
    root.setLevel(getattr(logging, ensure_text(level).upper(), logging.INFO))
