#!/usr/bin/env python3
"""tech-debt.py — 輕量級技術債評估工具。

掃描專案目錄，計算技術債分數（0-100）。
分數超過閾值時，Router 會觸發 REFACTOR。
"""

import argparse
import os
import re
import sys
from collections import defaultdict

# 預設掃描的原始碼副檔名
DEFAULT_EXTENSIONS = {
    "py", "js", "ts", "jsx", "tsx", "c", "cpp", "h", "hpp",
    "swift", "go", "rs", "java", "rb",
}

# 排除的目錄
EXCLUDED_DIRS = {
    "node_modules", ".git", "__pycache__", "build", "dist", "vendor",
    ".venv", "venv", "env", ".tox", ".mypy_cache", ".pytest_cache",
    "target", ".next", ".nuxt", "out", "coverage",
}

# 函式定義的 regex 模式
FUNC_PATTERN = re.compile(
    r"^\s*(?:"
    r"def\s+\w+|"                          # Python
    r"(?:async\s+)?function\s+\w+|"        # JavaScript / TypeScript
    r"(?:export\s+)?(?:async\s+)?function\s+\w+|"
    r"(?:pub\s+)?fn\s+\w+|"               # Rust
    r"func\s+\w+|"                         # Go / Swift
    r"(?:public|private|protected|static|void|int|float|double|char|bool|string|auto)\s+\w+\s*\(|"  # C/C++/Java
    r"(?:public|private|internal|fileprivate|open)\s+func\s+\w+"  # Swift 修飾詞
    r")"
)

# TODO/FIXME 等標記
TODO_PATTERN = re.compile(r"\b(TODO|FIXME|HACK|XXX)\b", re.IGNORECASE)

# Import 語句
IMPORT_PATTERN = re.compile(
    r"^\s*(?:"
    r"import\s|"
    r"from\s+\S+\s+import\s|"
    r"require\s*\(|"
    r"#include\s|"
    r"using\s+\w|"
    r"use\s+\w"
    r")"
)

MAX_FILES = 500


def collect_files(project_path, extensions=None, max_files=MAX_FILES):
    """收集專案中的原始碼檔案，回傳 list of (relative_path, absolute_path)。"""
    if extensions is None:
        extensions = DEFAULT_EXTENSIONS

    files = []
    for root, dirs, filenames in os.walk(project_path):
        # 排除不需要的目錄（就地修改 dirs 讓 os.walk 跳過）
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
        for fname in filenames:
            ext = fname.rsplit(".", 1)[-1] if "." in fname else ""
            if ext in extensions:
                abs_path = os.path.join(root, fname)
                rel_path = os.path.relpath(abs_path, project_path)
                files.append((rel_path, abs_path))
                if len(files) >= max_files:
                    return files
    return files


def read_file_lines(path):
    """安全讀取檔案，回傳行列表。"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.readlines()
    except (OSError, IOError):
        return []


# ── 各維度分析 ──────────────────────────────────────────────

def analyze_file_sizes(file_data):
    """維度 1：檔案大小（0-20）。"""
    if not file_data:
        return 0, 0, []
    large = [(rel, n) for rel, n, _, _, _ in file_data if n > 300]
    score = round(len(large) / len(file_data) * 20)
    return min(score, 20), len(large), large


def analyze_function_lengths(file_data):
    """維度 2：函式長度（0-20）。"""
    total_funcs = 0
    long_funcs = 0
    long_details = []  # (rel_path, func_line, length)

    for rel, _n, lines, _, _ in file_data:
        func_starts = []
        for i, line in enumerate(lines):
            if FUNC_PATTERN.match(line):
                func_starts.append(i)
        for idx, start in enumerate(func_starts):
            end = func_starts[idx + 1] if idx + 1 < len(func_starts) else len(lines)
            length = end - start
            total_funcs += 1
            if length > 50:
                long_funcs += 1
                long_details.append((rel, start + 1, length))

    if total_funcs == 0:
        return 0, 0, total_funcs, []
    score = round(long_funcs / total_funcs * 20)
    return min(score, 20), long_funcs, total_funcs, long_details


def analyze_todo_density(file_data):
    """維度 3：TODO/FIXME 密度（0-20）。"""
    total_lines = 0
    total_markers = 0
    file_markers = defaultdict(int)

    for rel, n, lines, _, _ in file_data:
        total_lines += n
        for line in lines:
            count = len(TODO_PATTERN.findall(line))
            if count:
                total_markers += count
                file_markers[rel] += count

    if total_lines == 0:
        density = 0.0
    else:
        density = total_markers / total_lines * 1000

    if density == 0:
        score = 0
    elif density <= 3:
        score = 5
    elif density <= 10:
        score = 10
    else:
        score = 20

    return score, total_markers, round(density, 1), file_markers


def analyze_duplication(file_data):
    """維度 4：重複程式碼（0-20）。連續 5 行以上完全相同的區塊。"""
    # 建立所有 5 行 window 的 hash
    block_locations = defaultdict(list)  # hash -> [(rel, start_line)]

    for rel, n, lines, _, _ in file_data:
        stripped = [l.strip() for l in lines]
        for i in range(len(stripped) - 4):
            block = tuple(stripped[i:i + 5])
            # 排除空白行組成的區塊
            if all(b == "" for b in block):
                continue
            block_locations[block].append((rel, i + 1))

    # 計算有多少個重複區塊（出現 2 次以上）
    dup_blocks = 0
    for _block, locations in block_locations.items():
        if len(locations) > 1:
            dup_blocks += 1

    # 用總函式數做分母（與 spec 一致）
    total_funcs = 0
    for _, _, lines, _, _ in file_data:
        for line in lines:
            if FUNC_PATTERN.match(line):
                total_funcs += 1

    if total_funcs == 0:
        score = min(dup_blocks, 20)
    else:
        score = round(dup_blocks / total_funcs * 20)

    return min(score, 20), dup_blocks


def analyze_import_complexity(file_data):
    """維度 5：依賴複雜度（0-20）。"""
    if not file_data:
        return 0, 0.0

    total_imports = 0
    for _, _, lines, _, _ in file_data:
        for line in lines:
            if IMPORT_PATTERN.match(line):
                total_imports += 1

    avg = total_imports / len(file_data)

    if avg <= 5:
        score = 0
    elif avg <= 10:
        score = 5
    elif avg <= 15:
        score = 10
    elif avg <= 20:
        score = 15
    else:
        score = 20

    return score, round(avg, 1)


# ── 主要分析函式 ────────────────────────────────────────────

def analyze_project(project_path, extensions=None, max_files=MAX_FILES):
    """分析專案並回傳完整結果 dict。可被 router.py import 使用。"""
    files = collect_files(project_path, extensions, max_files)

    # 讀取所有檔案
    file_data = []  # (rel_path, line_count, lines, long_func_count, todo_count)
    for rel, abs_path in files:
        lines = read_file_lines(abs_path)
        file_data.append((rel, len(lines), lines, 0, 0))

    # 各維度分析
    size_score, large_count, large_files = analyze_file_sizes(file_data)
    func_score, long_func_count, total_funcs, long_func_details = analyze_function_lengths(file_data)
    todo_score, todo_count, todo_density, file_todo_map = analyze_todo_density(file_data)
    dup_score, dup_blocks = analyze_duplication(file_data)
    import_score, avg_imports = analyze_import_complexity(file_data)

    overall = size_score + func_score + todo_score + dup_score + import_score

    # 組裝每個檔案的摘要資訊（用於 worst files）
    file_summaries = {}
    for rel, n, lines, _, _ in file_data:
        funcs_in_file = []
        func_starts = []
        for i, line in enumerate(lines):
            if FUNC_PATTERN.match(line):
                func_starts.append(i)
        long_in_file = 0
        for idx, start in enumerate(func_starts):
            end = func_starts[idx + 1] if idx + 1 < len(func_starts) else len(lines)
            if end - start > 50:
                long_in_file += 1
        todos_in_file = file_todo_map.get(rel, 0)
        # 計算「問題分數」用於排序
        problems = 0
        if n > 300:
            problems += n / 100
        problems += long_in_file * 3
        problems += todos_in_file
        file_summaries[rel] = {
            "lines": n,
            "long_functions": long_in_file,
            "todos": todos_in_file,
            "problem_score": problems,
        }

    worst = sorted(file_summaries.items(), key=lambda x: x[1]["problem_score"], reverse=True)

    return {
        "project_path": project_path,
        "total_files": len(file_data),
        "overall_score": overall,
        "dimensions": {
            "file_size": {"score": size_score, "large_count": large_count},
            "function_length": {"score": func_score, "long_count": long_func_count, "total_funcs": total_funcs},
            "todo_density": {"score": todo_score, "count": todo_count, "density": todo_density},
            "duplication": {"score": dup_score, "blocks": dup_blocks},
            "import_complexity": {"score": import_score, "avg_imports": avg_imports},
        },
        "worst_files": worst,
        "file_summaries": file_summaries,
    }


def get_score(project_path, extensions=None):
    """簡易介面：回傳整數分數，供 router.py 使用。"""
    result = analyze_project(project_path, extensions)
    return result["overall_score"]


# ── 輸出格式化 ──────────────────────────────────────────────

def format_report(result, worst_n=5):
    """格式化完整報告。"""
    d = result["dimensions"]
    lines = []
    lines.append(f"Tech Debt Report: {result['project_path']}")
    lines.append(f"Files scanned: {result['total_files']}")
    lines.append("")
    lines.append(f"Overall Score: {result['overall_score']}/100")
    lines.append("")
    lines.append("Dimension Breakdown:")
    lines.append(f"  File Size:      {d['file_size']['score']:>2}/20 ({d['file_size']['large_count']} files > 300 lines)")
    lines.append(f"  Function Length: {d['function_length']['score']:>2}/20 ({d['function_length']['long_count']} functions > 50 lines)")
    lines.append(f"  TODO Density:    {d['todo_density']['score']:>2}/20 ({d['todo_density']['density']} per 1000 lines)")
    lines.append(f"  Duplication:     {d['duplication']['score']:>2}/20 ({d['duplication']['blocks']} duplicate blocks)")
    lines.append(f"  Import Complex:  {d['import_complexity']['score']:>2}/20 (avg {d['import_complexity']['avg_imports']} imports/file)")

    worst = result["worst_files"][:worst_n]
    if worst:
        lines.append("")
        lines.append("Worst Files:")
        for rel, info in worst:
            if info["problem_score"] <= 0:
                continue
            parts = [f"{info['lines']} lines"]
            if info["long_functions"]:
                parts.append(f"{info['long_functions']} long functions")
            if info["todos"]:
                parts.append(f"{info['todos']} TODOs")
            lines.append(f"  {rel:<40s} {', '.join(parts)}")

    return "\n".join(lines)


# ── CLI ─────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="輕量級技術債評估工具")
    parser.add_argument("project_path", help="專案目錄路徑")
    parser.add_argument("--score-only", action="store_true", help="只輸出分數")
    parser.add_argument("--extensions", type=str, default=None,
                        help="指定副檔名，以逗號分隔（例：py,js,ts）")
    parser.add_argument("--worst", type=int, default=5, help="列出最需要重構的檔案數量")
    args = parser.parse_args()

    project_path = os.path.abspath(args.project_path)
    if not os.path.isdir(project_path):
        print(f"錯誤：{project_path} 不是有效的目錄", file=sys.stderr)
        sys.exit(1)

    extensions = None
    if args.extensions:
        extensions = set(args.extensions.split(","))

    result = analyze_project(project_path, extensions)

    if args.score_only:
        print(result["overall_score"])
    else:
        print(format_report(result, args.worst))


if __name__ == "__main__":
    main()
