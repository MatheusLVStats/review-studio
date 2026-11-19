"""Assemble the single-file artifact page (dist/index.html) and the local test harness (test/harness.html)."""
import base64
import pathlib

root = pathlib.Path(__file__).resolve().parent
shell = (root / "src" / "shell.html").read_text()
app = (root / "src" / "app.js").read_text()
logo = (root.parent / "platform" / "web" / "app" / "icon.svg").read_text()
logo_uri = "data:image/svg+xml;base64," + base64.b64encode(logo.encode()).decode()

page = shell.replace("%%LOGO%%", logo_uri).replace("%%APP%%", app)
(root / "dist").mkdir(exist_ok=True)
(root / "dist" / "index.html").write_text(page.replace("<!--MOCK-->\n", ""))
mock = (root / "test" / "mock-claude.js").read_text()
(root / "test" / "harness.html").write_text(page.replace("<!--MOCK-->", "<script>\n" + mock + "\n</script>"))
print("dist/index.html", len(page), "bytes")
