"""Drive the web UI as three different users in separate browser contexts.

Run against a fresh database with the API on :8000 and the web app on :3000 (see platform/README.md).
Optional: CHROME=/path/to/chrome to use an installed Chrome instead of Playwright's Chromium.
"""
import json, os, pathlib, re, urllib.request
from playwright.sync_api import sync_playwright, expect

API = os.environ.get("API_URL", "http://localhost:8000")
WEB = os.environ.get("WEB_URL", "http://localhost:3000")
SYN = pathlib.Path(__file__).resolve().parents[2] / "test-data" / "synthetic"
OUT = pathlib.Path(os.environ.get("SHOTS_DIR", "e2e-shots")); OUT.mkdir(exist_ok=True)

def api(path, body):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try: return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e: return json.load(e)

for n in ("lead", "ana", "bruno"):
    api("/auth/register", {"email": f"{n}@example.test", "display_name": n.capitalize(), "password": f"synthetic-{n}-pw"})

def login(browser, n):
    ctx = browser.new_context(viewport={"width": 1280, "height": 860}, accept_downloads=True)
    p = ctx.new_page()
    p.on("dialog", lambda d: d.accept())
    p.goto(WEB)
    p.get_by_label("E-mail").fill(f"{n}@example.test")
    p.get_by_label(re.compile("Password")).fill(f"synthetic-{n}-pw")
    p.get_by_role("button", name="Sign in").click()
    expect(p.get_by_role("heading", name="Your reviews")).to_be_visible()
    return p

with sync_playwright() as pw:
    b = pw.chromium.launch(executable_path=os.environ.get("CHROME") or None)
    lead = login(b, "lead")
    lead.get_by_label("Title").fill("SYNTHETIC UI test")
    lead.get_by_role("button", name="Create review").click()
    lead.get_by_role("link", name="SYNTHETIC UI test").click()
    for n in ("ana", "bruno"):
        lead.get_by_placeholder("E-mail of a registered user").fill(f"{n}@example.test")
        lead.get_by_role("button", name="Add member").click()
        expect(lead.get_by_role("cell", name=f"{n}@example.test")).to_be_visible()
    lead.get_by_role("button", name="Import and duplicates").click()
    for f in ("rayyan-test-medline.ris", "rayyan-test-embase.ris", "rayyan-test-central.bib", "rayyan-test-registry.csv"):
        lead.locator("input[type=file]").set_input_files(str(SYN / f))
        lead.get_by_role("button", name="Import file").click()
        expect(lead.get_by_role("status").filter(has_text=f).first).to_be_visible()
    lead.get_by_role("button", name="Find duplicates").click()
    expect(lead.get_by_role("status").filter(has_text="new pairs").first).to_be_visible()
    lead.screenshot(path=OUT / "1-duplicates.png", full_page=True)
    lead.get_by_role("button", name="Merge exact DOI/PMID matches").click()
    expect(lead.get_by_role("status").filter(has_text="merged").first).to_be_visible()
    row = lead.get_by_role("row").filter(has_text="Beta").filter(has_text="title_year")
    row.get_by_role("button", name="Merge").click()
    expect(lead.get_by_role("status").filter(has_text="Merged.").first).to_be_visible()
    lead.get_by_role("button", name="Overview").click()
    lead.get_by_role("checkbox", name="Ana").check(); lead.get_by_role("checkbox", name="Bruno").check()
    lead.get_by_role("button", name="Assign").click()
    expect(lead.get_by_role("status").filter(has_text="18 assignments added").first).to_be_visible()

    plan = {"Gamma": ("Include", "Exclude"), "Zeta": ("Include", "Include"), "Eta": ("Exclude", "Maybe")}
    pages = {}
    for i, n in enumerate(("ana", "bruno")):
        p = login(b, n); pages[n] = p
        p.get_by_role("link", name="SYNTHETIC UI test").click()
        p.get_by_role("button", name="Screening").click()
        for key, votes in plan.items():
            p.locator(".queue button").filter(has_text=re.compile(rf"\b{key}\b")).click()
            expect(p.locator(".votebar .target")).to_contain_text(re.compile(rf"\b{key}\b"))
            p.locator(".votebar").get_by_role("button", name=votes[i], exact=True).click()
            expect(p.get_by_role("status").filter(has_text=f"Saved: {votes[i].lower()}").first).to_be_visible()
        if n == "ana":
            p.screenshot(path=OUT / "2-ana-screening.png", full_page=True)
    # Ana must see Bruno's decisions nowhere while blinded.
    a = pages["ana"]
    a.locator(".queue button").filter(has_text=re.compile(r"\bGamma\b")).click()
    expect(a.get_by_text("Other reviewers' decisions are blinded.")).to_be_visible()
    assert "Bruno:" not in a.content()

    lead.get_by_role("button", name="Reconciliation").click()
    lead.get_by_role("button", name="Open reconciliation").click()
    expect(lead.get_by_role("status").filter(has_text="3 publications revealed").first).to_be_visible()
    expect(lead.get_by_role("heading", name="Conflicts (2)")).to_be_visible()
    lead.screenshot(path=OUT / "3-reconciliation.png", full_page=True)
    box = lead.locator(".record").filter(has_text="Gamma")
    box.get_by_placeholder("How the disagreement was settled").fill("Discussed; survey kept for full text.")
    box.get_by_role("button", name="Save resolution").click()
    expect(lead.get_by_role("status").filter(has_text="Resolution saved").first).to_be_visible()

    a.reload(); a.get_by_role("button", name="Screening").click()
    a.locator(".queue button").filter(has_text=re.compile(r"\bGamma\b")).click()
    expect(a.get_by_text("Bruno:")).to_be_visible()
    expect(a.get_by_text("Votes are locked")).to_be_visible()
    a.screenshot(path=OUT / "4-ana-after-reveal.png", full_page=True)

    lead.get_by_role("button", name="Export").click()
    with lead.expect_download() as d:
        lead.get_by_role("button", name="Title/abstract decisions (CSV)").click()
    csv_text = pathlib.Path(d.value.path()).read_text()
    print(csv_text.splitlines()[0])
    print(next(l for l in csv_text.splitlines() if "Gamma" in l))
    lead.screenshot(path=OUT / "5-export.png", full_page=True)
    b.close()
print("UI FLOW OK")
