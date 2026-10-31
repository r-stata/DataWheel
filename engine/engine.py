#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DataWheel 转换引擎
支持格式互转：xlsx/xls、csv/tsv、dta、rds/rdata、parquet、feather、json/jsonl
开发：微信公众号 RStata
用法:
  engine.py probe  --input FILE
  engine.py convert --input FILE --to FMT [--out DIR] [--sheet N|name]
输出: 单行 JSON（ensure_ascii=False）
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# pandas 缺失时引擎仍需能运行 check/install 子命令
try:
    import pandas as pd
except ImportError:
    pd = None

REQUIRED_PACKAGES = ["pandas", "pyarrow", "pyreadstat", "pyreadr", "openpyxl", "xlsxwriter", "xlrd"]


def check_packages():
    """检测依赖包：返回 {python, packages, missing, all_ok}"""
    packages = {}
    for name in REQUIRED_PACKAGES:
        try:
            __import__(name)
            packages[name] = True
        except Exception:
            packages[name] = False
    missing = [k for k, v in packages.items() if not v]
    return {
        "python": sys.executable,
        "version": "%d.%d.%d" % sys.version_info[:3],
        "packages": packages,
        "missing": missing,
        "all_ok": not missing,
    }


def install_missing():
    """pip 安装缺失包：默认源 → 清华镜像 → break-system-packages 兜底，逐行输出进度"""
    info = check_packages()
    missing = info["missing"]
    if not missing:
        return {"ok": True, "installed": [], "detail": "所有依赖已就绪"}

    mirror = ["-i", "https://pypi.tuna.tsinghua.edu.cn/simple"]
    attempts = [
        ("默认源", []),
        ("清华镜像", mirror),
        ("清华镜像(break-system-packages)", ["--break-system-packages"] + mirror),
    ]
    for label, extra in attempts:
        cmd = [sys.executable, "-m", "pip", "install", "--upgrade"] + extra + missing
        print(">> pip install (%s): %s" % (label, " ".join(missing)), flush=True)
        r = subprocess.run(cmd)
        if r.returncode == 0:
            return {"ok": True, "installed": missing, "detail": "安装完成: " + ", ".join(missing)}
        print(">> 该源安装失败，尝试下一个…", flush=True)
    return {"ok": False, "installed": [], "detail": "所有安装源均失败，请检查网络或手动安装: pip install " + " ".join(missing)}

READ_EXTS = {
    ".csv": "csv", ".tsv": "tsv", ".txt": "txt",
    ".xlsx": "xlsx", ".xls": "xls",
    ".dta": "dta",
    ".rds": "rds", ".rdata": "rdata",
    ".parquet": "parquet", ".pq": "parquet",
    ".feather": "feather", ".arrow": "feather",
    ".json": "json", ".jsonl": "jsonl", ".ndjson": "jsonl",
}

WRITE_EXTS = {
    "csv": ".csv", "tsv": ".tsv", "txt": ".txt", "xlsx": ".xlsx",
    "dta": ".dta", "rds": ".rds",
    "parquet": ".parquet", "feather": ".feather",
    "json": ".json", "jsonl": ".jsonl",
}


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()


def fail(msg, **extra):
    emit({"ok": False, "error": str(msg), **extra})
    sys.exit(1)


# ---------- 读取 ----------

def read_csv_smart(path, sep=","):
    # 常见编码依次尝试：utf-8-sig -> gbk -> utf-8 -> latin1
    for enc in ("utf-8-sig", "gbk", "utf-8", "latin1"):
        try:
            return pd.read_csv(path, sep=sep, encoding=enc)
        except (UnicodeDecodeError, pd.errors.ParserError):
            continue
    return pd.read_csv(path, sep=sep, encoding="latin1")


def read_table(path, fmt):
    if fmt == "csv":
        return read_csv_smart(path, ",")
    return read_csv_smart(path, "\t")


def read_txt(path):
    """txt 智能分列：嗅探分隔符（\\t , ; |），失败时按制表符/逗号/空白兜底"""
    import csv as _csv
    sample, enc_used = "", "utf-8-sig"
    for enc in ("utf-8-sig", "gbk", "utf-8", "latin1"):
        try:
            with open(path, "r", encoding=enc) as f:
                sample = "".join(f.readline() for _ in range(30))
            enc_used = enc
            break
        except (UnicodeDecodeError, LookupError):
            continue
    sep = None
    try:
        sep = _csv.Sniffer().sniff(sample, delimiters="\t,;|").delimiter
    except Exception:
        if "\t" in sample:
            sep = "\t"
        elif "," in sample:
            sep = ","
        elif re.search(r"\S\s+\S", sample):
            sep = r"\s+"   # 空白分列（对齐文本表）
    try:
        return pd.read_csv(path, sep=sep, encoding=enc_used, engine="python")
    except Exception:
        return pd.read_csv(path, sep=r"\s+", encoding="latin1", engine="python")


def read_excel(path, sheet=None):
    xl = pd.ExcelFile(path)
    names = xl.sheet_names
    if sheet is None:
        target = names[0]
    elif isinstance(sheet, str) and not sheet.isdigit():
        target = sheet
    else:
        idx = int(sheet)
        target = names[idx]
    df = xl.parse(target)
    others = [n for n in names if n != target]
    warn = ("工作簿包含多个工作表，已转换「%s」；其余: %s" % (target, ", ".join(others))) if others else None
    return df, warn


def read_dta(path):
    import pyreadstat
    df, meta = pyreadstat.read_dta(path)
    # 变量标签写入列属性，供后续写出参考
    try:
        for c in df.columns:
            lab = (meta.column_names_to_labels or {}).get(c)
            if lab:
                df.attrs["label_" + str(c)] = lab
    except Exception:
        pass
    return df, None


def read_r(path):
    import pyreadr
    res = pyreadr.read_r(path)
    for _k, v in res.items():
        if isinstance(v, pd.DataFrame):
            return v, None
    fail("R 数据文件中未找到数据框（data.frame）")


def read_json_any(path, fmt):
    if fmt == "jsonl":
        return pd.read_json(path, lines=True), None
    # 先按 records 数组尝试，失败再按行式 JSON
    try:
        return pd.read_json(path, orient="records"), None
    except ValueError:
        return pd.read_json(path, lines=True), None


def read_any(path, fmt, sheet=None):
    if fmt in ("csv", "tsv"):
        return read_table(path, fmt), None
    if fmt == "txt":
        return read_txt(path), None
    if fmt in ("xlsx", "xls"):
        return read_excel(path, sheet)
    if fmt == "dta":
        return read_dta(path)
    if fmt in ("rds", "rdata"):
        return read_r(path)
    if fmt == "parquet":
        return pd.read_parquet(path), None
    if fmt == "feather":
        return pd.read_feather(path), None
    if fmt in ("json", "jsonl"):
        return read_json_any(path, fmt)
    fail("不支持的读取格式: " + fmt)


# ---------- 写出 ----------

# Excel 单文件行数上限：xlsx 单表最多 1,048,576 行，留 1 行给表头
EXCEL_SPLIT_LIMIT = {"xlsx": 1048575}


def write_excel_split(df, out_path, target):
    """超出 Excel 行数上限时自动拆分为 _part1/_part2/… 多个文件。
    返回 (提示, 首个输出路径, 全部输出路径列表)"""
    limit = EXCEL_SPLIT_LIMIT[target]
    n = len(df)
    nparts = (n + limit - 1) // limit
    root, ext = os.path.splitext(out_path)
    outputs = []
    for i in range(nparts):
        chunk = df.iloc[i * limit:(i + 1) * limit]
        p = "%s_part%d%s" % (root, i + 1, ext)
        write_any(chunk, p, target)
        outputs.append(p)
        emit({"ok": True, "event": "stage", "stage": "writing",
              "part": i + 1, "total": nparts})
    note = ("共 %d 行，超出 Excel 单文件上限（%d 行数据），已自动拆分为 %d 个文件："
            "_part1 ~ _part%d，每个文件均含表头") % (n, limit, nparts, nparts)
    return note, outputs[0], outputs


def _clean_columns_for_stata(cols):
    """生成合法且不重复的 Stata 变量名（≤32 字符），返回 (新名列表, 是否有改动)"""
    out, seen, changed = [], set(), False
    for c in cols:
        s = str(c)
        s = re.sub(r"[^\w]", "_", s, flags=re.UNICODE)
        s = re.sub(r"_+", "_", s).strip("_")
        if not s:
            s = "var"
        if re.match(r"^\d", s):
            s = "v" + s
        if s != str(c):
            changed = True
        s = s[:32]
        base, i = s, 1
        while s in seen:
            suffix = "_" + str(i)
            s = base[: 32 - len(suffix)] + suffix
            i += 1
        seen.add(s)
        out.append(s)
    return out, changed


def _prep_dta(df):
    df = df.copy()
    df.columns, changed = _clean_columns_for_stata(df.columns)
    for c in df.columns:
        col = df[c]
        if isinstance(col.dtype, pd.CategoricalDtype):
            df[c] = col.astype(str).replace("nan", None)
        elif pd.api.types.is_datetime64_any_dtype(col):
            df[c] = col.dt.tz_localize(None) if col.dt.tz is not None else col
        elif col.dtype == object:
            df[c] = col.map(lambda x: None if x is None else (str(x) if not isinstance(x, str) else x))
    return df, changed


def write_dta(df, path, label=None):
    import pyreadstat
    df2, changed = _prep_dta(df)
    note = "已将变量名规范化以符合 Stata 命名规则" if changed else None
    pyreadstat.write_dta(df2, path, file_label=label or "数据处理：微信公众号 RStata")
    return note


def write_rds(df, path):
    # pyreadr 不支持写 rds，用 Rscript(arrow) 兜底
    tmp = tempfile.NamedTemporaryFile(suffix=".parquet", delete=False)
    tmp.close()
    try:
        df.to_parquet(tmp.name, index=False)
        r_code = (
            'df <- arrow::read_parquet("%s"); '
            'saveRDS(df, "%s", version = 2)'
        ) % (tmp.name.replace('"', '\\"'), path.replace('"', '\\"'))
        r = subprocess.run(["Rscript", "-e", r_code], capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            fail("写出 rds 失败（Rscript）: " + (r.stderr or "").strip()[-500:])
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
    return None


def write_json(df, path, lines=False):
    with open(path, "w", encoding="utf-8") as f:
        df.to_json(f, orient="records", lines=lines, force_ascii=False,
                   indent=None if lines else 2, date_format="iso")


def write_any(df, path, fmt, label=None):
    if fmt == "csv":
        df.to_csv(path, index=False, encoding="utf-8-sig")  # 带 BOM，Excel 打开中文不乱码
    elif fmt in ("tsv", "txt"):
        df.to_csv(path, index=False, sep="\t", encoding="utf-8")
    elif fmt == "xlsx":
        with pd.ExcelWriter(path, engine="xlsxwriter") as w:
            df.to_excel(w, index=False, sheet_name="data")
    elif fmt == "dta":
        return write_dta(df, path, label)
    elif fmt == "rds":
        return write_rds(df, path)
    elif fmt == "parquet":
        df.to_parquet(path, index=False)
    elif fmt == "feather":
        df.to_feather(path)
    elif fmt == "json":
        write_json(df, path, lines=False)
    elif fmt == "jsonl":
        write_json(df, path, lines=True)
    else:
        fail("不支持的写出格式: " + fmt)
    return None


# ---------- probe ----------

def probe(path):
    ext = os.path.splitext(path)[1].lower()
    fmt = READ_EXTS.get(ext)
    if not fmt:
        fail("无法识别的文件类型: " + ext)
    df, warn = read_any(path, fmt)
    cols = [{"name": str(c), "type": str(df[c].dtype)} for c in df.columns[:40]]
    preview = json.loads(df.head(5).to_json(orient="records", force_ascii=False, date_format="iso"))
    return {
        "ok": True, "path": path, "format": fmt,
        "rows": int(len(df)), "cols": int(df.shape[1]),
        "columns": cols, "preview": preview, "warning": warn,
    }


# ---------- convert ----------

def convert(path, target, outdir=None, sheet=None, label=None):
    if pd is None:
        fail("Python 依赖未安装（pandas 缺失），请在应用设置的「Python 环境」中一键安装")
    t0 = time.time()
    ext = os.path.splitext(path)[1].lower()
    fmt = READ_EXTS.get(ext)
    if not fmt:
        fail("无法识别的文件类型: " + ext)
    if target not in WRITE_EXTS:
        fail("不支持的输出格式: " + target)

    emit({"ok": True, "event": "stage", "stage": "reading"})
    df, warn = read_any(path, fmt, sheet=sheet)

    emit({"ok": True, "event": "stage", "stage": "writing"})
    base = os.path.splitext(os.path.basename(path))[0]
    outdir = outdir or os.path.dirname(path) or "."
    os.makedirs(outdir, exist_ok=True)
    out_path = os.path.join(outdir, base + WRITE_EXTS[target])
    # 避免覆盖同名输出（例如 csv -> csv 场景不会出现，但保险起见）
    if os.path.abspath(out_path) == os.path.abspath(path):
        out_path = os.path.join(outdir, base + "_converted" + WRITE_EXTS[target])
    i = 1
    while os.path.exists(out_path):
        out_path = os.path.join(outdir, "%s(%d)%s" % (base, i, WRITE_EXTS[target]))
        i += 1

    # Excel 目标：行数超限自动拆分 _part1/_part2/…
    note = None
    outputs = [out_path]
    if target in EXCEL_SPLIT_LIMIT and len(df) > EXCEL_SPLIT_LIMIT[target]:
        note, out_path, outputs = write_excel_split(df, out_path, target)
    else:
        note = write_any(df, out_path, target, label=label)

    return {
        "ok": True, "input": path, "output": out_path, "outputs": outputs,
        "rows": int(len(df)), "cols": int(df.shape[1]),
        "elapsed": round(time.time() - t0, 2),
        "warning": warn or note,
    }


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p1 = sub.add_parser("probe")
    p1.add_argument("--input", required=True)
    p2 = sub.add_parser("convert")
    p2.add_argument("--input", required=True)
    p2.add_argument("--to", required=True)
    p2.add_argument("--out", default=None)
    p2.add_argument("--sheet", default=None)
    p2.add_argument("--label", default=None, help="dta 数据标签（file label）")
    sub.add_parser("check")    # 检测依赖包
    sub.add_parser("install")  # 安装缺失依赖包
    args = ap.parse_args()

    if args.cmd == "check":
        emit(check_packages())
        return
    if args.cmd == "install":
        emit(install_missing())
        return

    if not os.path.exists(args.input):
        fail("文件不存在: " + args.input)

    try:
        if args.cmd == "probe":
            emit(probe(args.input))
        else:
            emit(convert(args.input, args.to, args.out, args.sheet, args.label))
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main()
