#!/usr/bin/env python3
"""Stop hook: if files changed after docs/todo.md was last touched, ask Claude to update todo checkboxes once."""
import json, os, subprocess, sys

data = json.load(sys.stdin)
if data.get("stop_hook_active"):
    sys.exit(0)  # already reminded in this stop chain; never loop

root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
if not root:
    sys.exit(0)
todo = os.path.join(root, "docs/todo.md")
out = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=root, capture_output=True, text=True).stdout
changed = [l[3:].split(" -> ")[-1].strip('"') for l in out.splitlines()]
changed = [p for p in changed if p != "docs/todo.md" and os.path.isfile(os.path.join(root, p))]
if not changed or not os.path.exists(todo):
    sys.exit(0)

latest = max(os.path.getmtime(os.path.join(root, p)) for p in changed)
if os.path.getmtime(todo) >= latest:
    sys.exit(0)  # todo touched after the latest change

print(json.dumps({
    "decision": "block",
    "reason": "파일이 바뀌었는데 docs/todo.md는 그 뒤로 갱신되지 않았습니다. 이번에 끝낸 항목을 '- [x] … (YYYY-MM-DD)'로 체크하고, 새 할 일은 맞는 이정표에 추가하세요. 해당 항목이 없으면 그렇다고 한 줄로 말하고 끝내세요.",
}, ensure_ascii=False))
