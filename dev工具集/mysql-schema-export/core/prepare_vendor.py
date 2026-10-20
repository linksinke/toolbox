# -*- coding: utf-8 -*-
"""离线依赖打包脚本（维护用，需联网）。

在有网络的机器上运行（建议 Python 3），从 PyPI 下载并解压到：
  vendor/python2/   # Python 2.7：pymysql + yaml
  vendor/python3/   # Python 3：pymysql + yaml

用法：
  python core/prepare_vendor.py

运行时由 support.setup_vendor() 按解释器自动选择对应目录。
"""

from __future__ import absolute_import, division, print_function, unicode_literals

import io
import json
import os
import shutil
import sys
import tarfile
import zipfile

try:
    from urllib.request import urlopen, urlretrieve
except ImportError:
    from urllib2 import urlopen  # noqa: F401
    from urllib import urlretrieve

# 项目根目录（core/ 的上一级）
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor")
# 下载缓存目录（可删除，下次会重新拉）
CACHE = os.path.join(ROOT, ".vendor_cache")

# 各解释器独立一套完整依赖，互不共用
# yaml_lib：PyYAML sdist 内源码目录，lib=Py2，lib3=Py3
PACKAGES = {
    "python2": {
        "pymysql": "0.10.1",  # 最后一批正式支持 Py2 的版本
        "pyyaml": "5.4.1",
        "yaml_lib": "lib",
    },
    "python3": {
        "pymysql": "1.1.1",
        "pyyaml": "5.4.1",
        "yaml_lib": "lib3",
    },
}


def _pypi_urls(name, version):
    """查询 PyPI JSON API，返回该版本的文件列表（urls）。"""
    url = "https://pypi.org/pypi/{0}/{1}/json".format(name, version)
    data = json.loads(urlopen(url).read().decode("utf-8"))
    return data["urls"]


def _download(url, dest):
    """下载 url 到 dest；必要时创建父目录。"""
    if not os.path.isdir(os.path.dirname(dest)):
        os.makedirs(os.path.dirname(dest))
    print("download:", url)
    urlretrieve(url, dest)
    return dest


def _pick_pymysql_wheel(urls):
    """从 PyPI urls 中挑选 PyMySQL 的 wheel 包。"""
    for item in urls:
        if item.get("packagetype") == "bdist_wheel" and item["filename"].endswith(".whl"):
            return item
    raise RuntimeError("未找到 PyMySQL wheel")


def _pick_pyyaml_sdist(urls):
    """从 PyPI urls 中挑选 PyYAML 的 sdist（需从中取纯 Python 源码）。"""
    for item in urls:
        if item.get("packagetype") == "sdist":
            return item
    raise RuntimeError("未找到 PyYAML sdist")


def _extract_pymysql(wheel_path, target_dir):
    """从 wheel 中解压 pymysql/ 包到 target_dir。"""
    with zipfile.ZipFile(wheel_path) as zf:
        for name in zf.namelist():
            if name.startswith("pymysql/"):
                zf.extract(name, target_dir)


def _extract_yaml(sdist_path, target_dir, lib_name):
    """从 PyYAML sdist 中解压 lib/yaml 或 lib3/yaml 到 target_dir/yaml。"""
    marker = "/{0}/yaml/".format(lib_name)
    with tarfile.open(sdist_path, "r:gz") as tf:
        for member in tf.getmembers():
            if member.isdir():
                continue
            norm = member.name.replace("\\", "/")
            if marker not in norm:
                continue
            # 去掉前缀，只保留 yaml/... 相对路径
            rel = norm[norm.find(marker) + len("/{0}/".format(lib_name)) :]
            out = os.path.join(target_dir, rel.replace("/", os.sep))
            parent = os.path.dirname(out)
            if not os.path.isdir(parent):
                os.makedirs(parent)
            src = tf.extractfile(member)
            with open(out, "wb") as fh:
                fh.write(src.read())


def prepare_one(runtime, cfg):
    """为单个 runtime（python2 / python3）生成完整 vendor 目录。"""
    out_dir = os.path.join(VENDOR, runtime)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    # 1) PyMySQL wheel
    pm_urls = _pypi_urls("PyMySQL", cfg["pymysql"])
    pm_item = _pick_pymysql_wheel(pm_urls)
    pm_path = os.path.join(CACHE, pm_item["filename"])
    if not os.path.isfile(pm_path):
        _download(pm_item["url"], pm_path)
    _extract_pymysql(pm_path, out_dir)

    # 2) PyYAML 纯 Python 源码（按解释器选 lib / lib3）
    y_urls = _pypi_urls("PyYAML", cfg["pyyaml"])
    y_item = _pick_pyyaml_sdist(y_urls)
    y_path = os.path.join(CACHE, y_item["filename"])
    if not os.path.isfile(y_path):
        _download(y_item["url"], y_path)
    _extract_yaml(y_path, out_dir, cfg["yaml_lib"])

    # 3) 版本标记，便于现场排查「到底装了哪一版」
    meta = os.path.join(out_dir, "VENDOR_META.txt")
    with open(meta, "w") as fh:
        fh.write("runtime={0}\n".format(runtime))
        fh.write("PyMySQL={0}\n".format(cfg["pymysql"]))
        fh.write("PyYAML={0} ({1})\n".format(cfg["pyyaml"], cfg["yaml_lib"]))

    print("ready:", out_dir)


def main():
    """生成 python2 / python3 两套离线包，并刷新 vendor/README.txt。"""
    if not os.path.isdir(CACHE):
        os.makedirs(CACHE)
    if not os.path.isdir(VENDOR):
        os.makedirs(VENDOR)

    for runtime, cfg in PACKAGES.items():
        prepare_one(runtime, cfg)

    # 清理历史目录结构（shared / py2 / py3）
    for old in ("shared", "py2", "py3"):
        old_path = os.path.join(VENDOR, old)
        if os.path.isdir(old_path):
            shutil.rmtree(old_path)
            print("removed old:", old_path)

    readme = os.path.join(VENDOR, "README.txt")
    with io.open(readme, "w", encoding="utf-8") as fh:
        fh.write(
            "\n".join(
                [
                    "离线 Python 依赖（按解释器分开，互不共用）",
                    "",
                    "  vendor/python2/   -> 仅给 Python 2.7 使用",
                    "  vendor/python3/   -> 仅给 Python 3 使用",
                    "",
                    "启动时会按当前 python 版本自动选择：",
                    "  Python 2.x  => vendor/python2",
                    "  Python 3.x  => vendor/python3",
                    "",
                    "也可强制指定（调试用）：",
                    "  set MYSQL_SCHEMA_EXPORT_VENDOR=python2",
                    "  set MYSQL_SCHEMA_EXPORT_VENDOR=python3",
                    "",
                    "更新离线包（需联网，建议 Python 3）：",
                    "  python core/prepare_vendor.py",
                    "",
                ]
            )
        )
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
