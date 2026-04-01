#!/usr/bin/env python3
"""roadmap.py — Roadmap 管理器，用於定義專案長期計畫。

Router 透過此模組決定下一個 BUILD 目標。
支援 CLI 與 import 兩種使用方式。
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "Error: PyYAML 未安裝。請執行 pip install pyyaml",
        file=sys.stderr,
    )
    sys.exit(1)

VALID_STATUSES = {"done", "in_progress", "pending"}


# ---------------------------------------------------------------------------
# 核心資料操作
# ---------------------------------------------------------------------------

def load_roadmap(path: str) -> dict:
    """載入並回傳 roadmap YAML 內容。"""
    p = Path(path)
    if not p.exists():
        print(f"Error: 找不到 roadmap 檔案: {path}", file=sys.stderr)
        sys.exit(1)
    with open(p, encoding="utf-8") as f:
        return yaml.safe_load(f)


def save_roadmap(path: str, data: dict):
    """將 roadmap 資料寫回 YAML 檔案。"""
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(
            data, f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )


def find_roadmap(specified: str = None, project_dir: str = None) -> str:
    """依搜尋順序尋找 roadmap 檔案路徑。

    順序：引數指定 > project_dir/roadmap.yaml > project_dir/.harness/roadmap.yaml
    """
    if specified:
        return specified
    base = Path(project_dir) if project_dir else Path.cwd()
    candidates = [
        base / "roadmap.yaml",
        base / ".harness" / "roadmap.yaml",
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    return None


def _all_features(data: dict) -> list:
    """回傳所有 (milestone, feature) 的扁平列表。"""
    result = []
    for ms in data.get("milestones", []):
        for feat in ms.get("features", []):
            result.append((ms, feat))
    return result


def _all_ids(data: dict) -> set:
    """回傳所有 milestone 和 feature 的 ID 集合。"""
    ids = set()
    for ms in data.get("milestones", []):
        ids.add(ms["id"])
        for feat in ms.get("features", []):
            ids.add(feat["id"])
    return ids


def _feature_by_id(data: dict, feature_id: str):
    """依 ID 尋找 feature，回傳 (milestone, feature) 或 (None, None)。"""
    for ms in data.get("milestones", []):
        for feat in ms.get("features", []):
            if feat["id"] == feature_id:
                return ms, feat
    return None, None


def _is_dep_satisfied(data: dict, dep_id: str) -> bool:
    """檢查某個依賴（milestone 或 feature）是否已完成。"""
    # 先找 feature
    for ms in data.get("milestones", []):
        if ms["id"] == dep_id:
            return ms.get("status") == "done"
        for feat in ms.get("features", []):
            if feat["id"] == dep_id:
                return feat.get("status") == "done"
    return False


def _milestone_deps_satisfied(data: dict, ms: dict) -> bool:
    """檢查 milestone 層級的 depends_on 是否都滿足。"""
    for dep_id in ms.get("depends_on", []):
        if not _is_dep_satisfied(data, dep_id):
            return False
    return True


# ---------------------------------------------------------------------------
# 公開 API（可被 router.py import）
# ---------------------------------------------------------------------------

def get_status(data: dict) -> dict:
    """計算 roadmap 進度摘要。

    回傳 dict 包含：name, total, done, percent, current_milestone, next_features
    """
    all_feats = _all_features(data)
    total = len(all_feats)
    done = sum(1 for _, f in all_feats if f.get("status") == "done")
    percent = int(done / total * 100) if total else 0

    # 找 current milestone（第一個 in_progress 或第一個非 done）
    current_ms = None
    for ms in data.get("milestones", []):
        if ms.get("status") == "in_progress":
            current_ms = ms
            break
    if current_ms is None:
        for ms in data.get("milestones", []):
            if ms.get("status") != "done":
                current_ms = ms
                break

    ms_done = 0
    ms_total = 0
    if current_ms:
        feats = current_ms.get("features", [])
        ms_total = len(feats)
        ms_done = sum(1 for f in feats if f.get("status") == "done")

    next_feats = get_available_features(data)

    return {
        "name": data.get("name", "unknown"),
        "total": total,
        "done": done,
        "percent": percent,
        "current_milestone": {
            "id": current_ms["id"],
            "name": current_ms["name"],
            "done": ms_done,
            "total": ms_total,
        } if current_ms else None,
        "next_features": next_feats,
    }


def get_available_features(data: dict) -> list:
    """取得所有目前可執行的 feature（依賴皆滿足、狀態為 pending）。

    回傳 list of dict，每個包含 id, name, milestone, verify, depends_on。
    """
    available = []
    for ms in data.get("milestones", []):
        # milestone 自身的依賴必須滿足
        if not _milestone_deps_satisfied(data, ms):
            continue
        for feat in ms.get("features", []):
            if feat.get("status") != "pending":
                continue
            deps = feat.get("depends_on", [])
            if all(_is_dep_satisfied(data, d) for d in deps):
                available.append({
                    "id": feat["id"],
                    "name": feat["name"],
                    "milestone": ms["id"],
                    "verify": feat.get("verify"),
                    "depends_on": deps,
                })
    return available


def get_next_feature(data: dict):
    """取得下一個可執行的 feature。無可用時回傳 None。"""
    available = get_available_features(data)
    return available[0] if available else None


def mark_feature_done(path: str, feature_id: str) -> bool:
    """標記 feature 為 done，並自動更新 milestone 狀態。

    回傳 True 表示成功，False 表示找不到 feature。
    """
    data = load_roadmap(path)
    ms, feat = _feature_by_id(data, feature_id)
    if feat is None:
        return False

    feat["status"] = "done"

    # 若 milestone 下所有 feature 都 done → 自動標記 milestone 為 done
    all_done = all(
        f.get("status") == "done" for f in ms.get("features", [])
    )
    if all_done:
        ms["status"] = "done"
    elif ms.get("status") == "pending":
        ms["status"] = "in_progress"

    save_roadmap(path, data)
    return True


def validate_roadmap(data: dict) -> list:
    """驗證 roadmap YAML 格式。回傳錯誤訊息列表（空 = 通過）。"""
    errors = []
    all_ids = _all_ids(data)

    if not data.get("name"):
        errors.append("缺少 name 欄位")
    if not data.get("milestones"):
        errors.append("缺少 milestones 欄位")
        return errors

    seen_ids = set()
    for ms in data["milestones"]:
        ms_id = ms.get("id")
        if not ms_id:
            errors.append(f"Milestone 缺少 id: {ms.get('name', '?')}")
            continue

        if ms_id in seen_ids:
            errors.append(f"重複的 ID: {ms_id}")
        seen_ids.add(ms_id)

        if ms.get("status") not in VALID_STATUSES:
            errors.append(f"Milestone {ms_id} 的 status 不合法: {ms.get('status')}")

        # 檢查 milestone depends_on
        for dep in ms.get("depends_on", []):
            if dep not in all_ids:
                errors.append(f"Milestone {ms_id} 的 depends_on 引用不存在的 ID: {dep}")

        for feat in ms.get("features", []):
            f_id = feat.get("id")
            if not f_id:
                errors.append(f"Feature 缺少 id（在 milestone {ms_id} 中）")
                continue

            if f_id in seen_ids:
                errors.append(f"重複的 ID: {f_id}")
            seen_ids.add(f_id)

            if feat.get("status") not in VALID_STATUSES:
                errors.append(
                    f"Feature {f_id} 的 status 不合法: {feat.get('status')}"
                )

            for dep in feat.get("depends_on", []):
                if dep not in all_ids:
                    errors.append(
                        f"Feature {f_id} 的 depends_on 引用不存在的 ID: {dep}"
                    )

    # 循環依賴檢測
    cycle_errors = _detect_cycles(data)
    errors.extend(cycle_errors)

    return errors


def _detect_cycles(data: dict) -> list:
    """檢查 feature/milestone 間是否有循環依賴。"""
    errors = []
    # 建立鄰接表
    graph = {}
    for ms in data.get("milestones", []):
        graph[ms["id"]] = ms.get("depends_on", [])
        for feat in ms.get("features", []):
            graph[feat["id"]] = feat.get("depends_on", [])

    # DFS 檢測
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {node: WHITE for node in graph}

    def dfs(node):
        color[node] = GRAY
        for neighbor in graph.get(node, []):
            if neighbor not in color:
                continue
            if color[neighbor] == GRAY:
                errors.append(f"循環依賴: {node} → {neighbor}")
                return
            if color[neighbor] == WHITE:
                dfs(neighbor)
        color[node] = BLACK

    for node in graph:
        if color[node] == WHITE:
            dfs(node)

    return errors


def init_roadmap(path: str, name: str, description: str = ""):
    """建立空白 roadmap YAML 檔案。"""
    data = {
        "name": name,
        "description": description or "",
        "test_cmd": "",
        "milestones": [],
    }
    save_roadmap(path, data)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_status(data: dict):
    """印出進度摘要。"""
    s = get_status(data)
    print(f"Roadmap: {s['name']}")
    print(f"Progress: {s['done']}/{s['total']} features done ({s['percent']}%)")

    if s["current_milestone"]:
        cm = s["current_milestone"]
        print(f"Current Milestone: {cm['id']} ({cm['done']}/{cm['total']} features done)")

    if s["next_features"]:
        print()
        print("Next available features:")
        for feat in s["next_features"]:
            deps_str = ""
            if feat["depends_on"]:
                dep_parts = []
                for d in feat["depends_on"]:
                    dep_parts.append(f"{d} ✓")
                deps_str = f"（depends: {', '.join(dep_parts)}）"
            print(f"  - {feat['id']}: {feat['name']}{deps_str}")
    else:
        print("\nNo available features (all done or blocked).")


def main():
    parser = argparse.ArgumentParser(
        description="Roadmap 管理器 — 專案長期計畫定義與查詢"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # status
    st = sub.add_parser("status", help="輸出進度摘要")
    st.add_argument("roadmap", help="Roadmap YAML 檔案路徑")

    # next
    nx = sub.add_parser("next", help="回傳下一個可執行的 feature（JSON）")
    nx.add_argument("roadmap", help="Roadmap YAML 檔案路徑")

    # mark-done
    md = sub.add_parser("mark-done", help="標記 feature 完成")
    md.add_argument("roadmap", help="Roadmap YAML 檔案路徑")
    md.add_argument("feature_id", help="Feature ID")

    # validate
    vl = sub.add_parser("validate", help="驗證 YAML 格式")
    vl.add_argument("roadmap", help="Roadmap YAML 檔案路徑")

    # init
    ini = sub.add_parser("init", help="建立空白 roadmap")
    ini.add_argument("roadmap", help="輸出 YAML 檔案路徑")
    ini.add_argument("--name", required=True, help="專案名稱")
    ini.add_argument("--description", default="", help="專案描述")

    args = parser.parse_args()

    if args.command == "status":
        data = load_roadmap(args.roadmap)
        _print_status(data)

    elif args.command == "next":
        data = load_roadmap(args.roadmap)
        feat = get_next_feature(data)
        print(json.dumps(feat, ensure_ascii=False, indent=2))

    elif args.command == "mark-done":
        ok = mark_feature_done(args.roadmap, args.feature_id)
        if not ok:
            print(f"Error: 找不到 feature: {args.feature_id}", file=sys.stderr)
            sys.exit(1)
        print(f"Feature {args.feature_id} → done")

    elif args.command == "validate":
        data = load_roadmap(args.roadmap)
        errors = validate_roadmap(data)
        if errors:
            print("Validation errors:")
            for e in errors:
                print(f"  - {e}")
            sys.exit(1)
        else:
            print("Roadmap 驗證通過 ✓")

    elif args.command == "init":
        init_roadmap(args.roadmap, args.name, args.description)
        print(f"已建立空白 roadmap: {args.roadmap}")


if __name__ == "__main__":
    main()
