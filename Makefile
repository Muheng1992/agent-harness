.PHONY: init setup-db setup-worktrees import-tasks run-once run-parallel run-loop run-loop-parallel status clean

# Initialize everything
init: setup-db setup-worktrees

# Create and initialize the database
setup-db:
	mkdir -p db
	sqlite3 db/agent.db < schema.sql

# Setup git worktrees for parallel workers
setup-worktrees:
	bash setup-worktrees.sh

# Import task definitions from a directory
# Usage: make import-tasks DIR=tasks/examples
import-tasks:
	python3 task_picker.py import $(DIR)

# Run a single orchestration round
run-once:
	bash orchestrator.sh

# Run parallel orchestration round
run-parallel:
	bash parallel-orchestrator.sh

# Run loop until all tasks complete (single-threaded)
run-loop:
	bash loop-orchestrator.sh

# Run loop until all tasks complete (parallel)
run-loop-parallel:
	bash loop-orchestrator.sh --parallel

# Show status
status:
	./agent-ctl status

# Clean up (WARNING: removes database and worktrees)
clean:
	rm -f db/agent.db db/agent.db-wal db/agent.db-shm
	rm -rf .worktrees/
	rm -f logs/*.log
