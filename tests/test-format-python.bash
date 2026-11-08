#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 -B - "$repo_root" << 'PY'
import ast
import contextlib
import io
import runpy
import sys
import tempfile
import tokenize
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

root = Path(sys.argv[1])
formatter = root / "scripts/format-python.py"
namespace = runpy.run_path(str(formatter))
format_source = namespace["_format"]
cases = [
    ("prepare()\nif ready:\n    run()\n", "prepare()\n\nif ready:\n    run()\n"),
    ("prepare()\nfor item in items:\n    run(item)\n", "prepare()\n\nfor item in items:\n    run(item)\n"),
    ("value = load()\n\nif value:\n    use(value)\n", "value = load()\nif value:\n    use(value)\n"),
    ("value = load()\nif value:\n    run()\n", "value = load()\nif value:\n    run()\n"),
    ("prepare()\nx = [\n    1,\n]\nrun()\n", "prepare()\n\nx = [\n    1,\n]\n\nrun()\n"),
    ("prepare()\nx = Order(\n    1,\n)\nrun()\n", "prepare()\n\nx = Order(\n    1,\n)\n\nrun()\n"),
    ("x = load(\n    1,\n)\nrun()\n", "x = load(\n    1,\n)\nrun()\n"),
    ("prepare()\nx = [1]\nrun()\n", "prepare()\nx = [1]\nrun()\n"),
    ("prepare()\n# Branch\nif ready:\n    run()\n", "prepare()\n\n# Branch\nif ready:\n    run()\n"),
    ("# fmt: off\nprepare()\nif ready:\n    run()\n# fmt: on\n", "# fmt: off\nprepare()\nif ready:\n    run()\n# fmt: on\n"),
    ('"""Module."""\nif ready:\n    run()\n', '"""Module."""\nif ready:\n    run()\n'),
]
for source, expected in cases:
    for newline in ("\n", "\r\n"):
        original = source.replace("\n", newline)
        wanted = expected.replace("\n", newline)
        result, diagnostics = format_source(original)
        assert result == wanted, (original, result, wanted)
        assert bool(diagnostics) == (original != wanted)
        assert ast.dump(ast.parse(result)) == ast.dump(ast.parse(original))
        original_tokens = [
            (token.type, token.string)
            for token in tokenize.generate_tokens(io.StringIO(original).readline)
            if token.type != tokenize.NL
        ]
        result_tokens = [
            (token.type, token.string)
            for token in tokenize.generate_tokens(io.StringIO(result).readline)
            if token.type != tokenize.NL
        ]
        assert result_tokens == original_tokens
        assert format_source(result) == (result, [])

# Both repositories keep discovery anchored to their own Ruff configuration
with tempfile.TemporaryDirectory(prefix="nautilus-python-format-") as directory:
    checkout = Path(directory).resolve() / "generated" / "checkout"
    (checkout / "scripts").mkdir(parents=True)
    selected = checkout / "selected.py"
    source = "prepare()\nif ready:\n    run()\n"
    selected.write_text(source, encoding="utf-8")
    for config in (checkout / "pyproject.toml", checkout / "python" / "pyproject.toml"):
        config.parent.mkdir(exist_ok=True)
        config.write_text("[tool.ruff]\n", encoding="utf-8")
        script = str(checkout / "scripts" / formatter.name)
        discovered = SimpleNamespace(returncode=0, stdout=str(selected) + "\n")
        with patch.dict(namespace["_paths"].__globals__, {"__file__": script}):
            with patch("subprocess.run", return_value=discovered) as run:
                assert list(namespace["_paths"]([selected])) == [selected]
                command = run.call_args.args[0]
                assert command[command.index("--config") + 1] == str(config), command
                assert "--force-exclude" in command

    invalid = checkout / "invalid.py"
    invalid.write_text("def broken(:\n", encoding="utf-8")
    with patch.object(sys, "argv", [str(formatter), "--fix", str(checkout)]):
        with patch.dict(namespace["_main"].__globals__, {"_paths": lambda paths: iter([selected, invalid])}):
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                assert namespace["_main"]() == 2
            assert "Python formatting failed:" in errors.getvalue()
    assert selected.read_text(encoding="utf-8") == source

print("All Python formatting tests passed")
PY
