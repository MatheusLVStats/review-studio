"""Play the whole flow as three people (lead = owner, Ana and Bruno = Contributors) against the mock.
Run: python build.py && python -m http.server 8765 --directory . & ; python test/flow_test.py"""
import os
import pathlib
import re

from playwright.sync_api import expect, sync_playwright

URL = os.environ.get("HARNESS", "http://localhost:8765/test/harness.html")
SYN = pathlib.Path(__file__).resolve().parents[2] / "test-data" / "synthetic"
SHOTS = pathlib.Path(os.environ.get("SHOTS_DIR", "/tmp/fm-shots")); SHOTS.mkdir(exist_ok=True)
PLAN = {"Gamma": ("Include", "Exclude"), "Zeta": ("Include", "Include"), "Eta": ("Exclude", "Maybe"), "Epsilon": ("Exclude", "Exclude"), "Theta": ("Include", "Maybe")}
word = lambda w: re.compile(rf"\b{w}\b")  # noqa: E731


def status(page, text):
    expect(page.locator("#msg")).to_contain_text(text, timeout=10000)


with sync_playwright() as pw:
    b = pw.chromium.launch(executable_path=os.environ.get("CHROME") or None)
    ctx = b.new_context(viewport={"width": 1280, "height": 860}, accept_downloads=True)
    lead = ctx.new_page(); lead.goto(URL + "?as=lead"); lead.evaluate("localStorage.clear()"); lead.reload()
    lead.get_by_label("Title").fill("SYNTHETIC FishingMeta test")
    lead.get_by_label(re.compile("Eligibility criteria")).fill("Adults having eye surgery under regional block; randomised or cohort; any comparator.")
    lead.get_by_role("button", name="Create review").click()
    expect(lead.get_by_role("heading", name="Summary")).to_be_visible()

    lead.get_by_role("button", name="Import and duplicates").click()
    for f in ("rayyan-test-medline.ris", "rayyan-test-embase.ris", "rayyan-test-central.bib", "rayyan-test-registry.csv"):
        lead.locator("#file").set_input_files(str(SYN / f))
        status(lead, f + ":")
    lead.get_by_role("button", name="Find duplicates").click(); status(lead, "new pairs")
    lead.get_by_role("button", name="Merge exact DOI/PMID matches").click(); status(lead, "exact DOI/PMID pairs merged")
    lead.get_by_role("row").filter(has_text="Beta").filter(has_text="Same title").get_by_role("button", name="Merge").click(); status(lead, "Merged")
    lead.screenshot(path=SHOTS / "1-duplicates.png", full_page=True)
    lead.get_by_role("button", name="Overview").click()
    expect(lead.get_by_text(re.compile(r"13 records imported · 4 duplicates merged · 9 publications"))).to_be_visible()
    for n in ("Ana", "Bruno"):
        lead.get_by_label("Search people").click()
        lead.get_by_label("Person").select_option(label=n)
        lead.get_by_role("button", name="Add to review").click(); status(lead, "Member added")
    lead.get_by_role("checkbox", name="Ana").check(); lead.get_by_role("checkbox", name="Bruno").check()
    lead.get_by_role("button", name="Assign", exact=True).click(); status(lead, "18 assignments added")

    pages = {}
    for i, n in enumerate(("ana", "bruno")):
        p = ctx.new_page(); p.goto(URL + "?as=" + n); pages[n] = p
        p.get_by_role("button", name="SYNTHETIC FishingMeta test").click()
        p.get_by_role("button", name="Title and abstract").click()
        for key, votes in PLAN.items():
            p.locator(".queue button").filter(has_text=word(key)).first.click()
            expect(p.locator(".votebar .target")).to_contain_text(word(key))
            p.locator(".votebar").get_by_role("button", name=votes[i], exact=True).click()
            status(p, "Saved: " + votes[i].lower())
        if n == "ana":
            p.locator(".queue button").filter(has_text=word("Alpha")).first.click()
            p.get_by_role("button", name="Ask Claude").click()
            expect(p.locator(".ai")).to_contain_text("not a vote")
            p.screenshot(path=SHOTS / "2-ana-screening.png", full_page=True)

    ana, bruno = pages["ana"], pages["bruno"]
    # Reviewers are Editors of the page but must not see lead controls.
    expect(ana.get_by_role("button", name="Import and duplicates")).to_have_count(0)
    ana.get_by_role("button", name="Reconciliation").click()
    expect(ana.get_by_role("button", name=re.compile("Open reconciliation"))).to_have_count(0)
    expect(ana.locator("header .who")).to_have_text("Reviewer")
    # Blinded: Ana sees no team decisions anywhere; progress shows counts only.
    ana.get_by_role("button", name="Overview").click()
    expect(ana.get_by_text("Blinded until reconciliation").first).to_be_visible()
    prog = ana.locator("table").nth(1).inner_text()
    assert "Bruno" in prog and "5" in prog and "exclude" not in prog.lower(), prog
    ana.get_by_role("button", name="Title and abstract").click()
    ana.get_by_role("button", name="All mine").click()
    ana.locator(".queue button").filter(has_text=word("Gamma")).first.click()
    expect(ana.get_by_text("Other reviewers' decisions stay hidden until reconciliation.")).to_be_visible()
    ana.get_by_role("button", name="Export").click(); ana.get_by_role("button", name="Decisions (CSV)").click()
    csv_ana = ana.evaluate("window.__downloads.at(-1).data")
    gamma = next(l for l in csv_ana.splitlines() if "Gamma" in l)
    assert "[blinded]" in gamma and "exclude" not in gamma, gamma
    # Ana changes a vote: history kept.
    ana.get_by_role("button", name="Title and abstract").click()
    ana.locator(".queue button").filter(has_text=word("Zeta")).first.click()
    ana.locator(".votebar").get_by_role("button", name="Maybe", exact=True).click(); status(ana, "Changed to maybe")
    ana.locator(".votebar").get_by_role("button", name="Include", exact=True).click(); status(ana, "Changed to include")
    expect(ana.locator(".votebar .target")).to_contain_text("changed 2×")

    lead.get_by_role("button", name="Reconciliation").click()
    lead.get_by_role("button", name=re.compile("Open reconciliation")).click(); status(lead, "Reconciliation opened")
    lead.wait_for_timeout(2000)
    print("released keys:", lead.evaluate("Object.keys(localStorage).filter(k=>k.startsWith('fm:released'))"))
    print("bruno msg:", bruno.locator('#msg').inner_text(), "| ana msg:", ana.locator('#msg').inner_text())
    expect(lead.get_by_role("heading", name="Conflicts (2)")).to_be_visible(timeout=15000)
    lead.screenshot(path=SHOTS / "3-reconciliation.png", full_page=True)
    box = lead.locator(".card").filter(has_text="Gamma")
    box.get_by_label("Resolution note").fill("Discussed; survey kept for full text.")
    box.get_by_role("button", name="Save resolution").click(); status(lead, "Resolution saved")
    expect(lead.get_by_text(re.compile(r"Ana / Bruno"))).to_be_visible()
    k = lead.locator("table").last.inner_text(); print("agreement:", k.replace("\n", " | "))
    assert "0.40" in k, k  # Zeta's FIRST votes agree; 2 of 5 agree

    # ---- Full text: Gamma (resolved include), Zeta and Theta reach this stage.
    lead.get_by_role("button", name="Overview").click()
    lead.get_by_role("checkbox", name="Ana").check(); lead.get_by_role("checkbox", name="Bruno").check()
    lead.get_by_label("Stage to assign").select_option("ft")
    lead.get_by_role("button", name="Assign", exact=True).click(); status(lead, "6 assignments added")
    lead.get_by_role("button", name="Full text").click()
    expect(lead.get_by_role("heading", name="Full texts to retrieve (3)")).to_be_visible()
    lead.get_by_label("Attach PDF").first.set_input_files(files=[{"name": "zeta.pdf", "mimeType": "application/pdf", "buffer": b"%PDF-1.4 synthetic"}])
    status(lead, "PDF attached")
    FT = {"Gamma": ("Exclude", "Exclude"), "Zeta": ("Include", "Include"), "Theta": ("Include", "Include")}
    for i, n in enumerate(("ana", "bruno")):
        p = pages[n]; p.get_by_role("button", name="Full text").click()
        for key, votes in FT.items():
            p.locator(".queue button").filter(has_text=word(key)).first.click()
            expect(p.locator(".votebar .target")).to_contain_text(word(key))
            if votes[i] == "Exclude":
                p.get_by_label("Reason for excluding").select_option("Wrong study design")
            p.locator(".votebar").get_by_role("button", name=votes[i], exact=True).click(); status(p, "Saved")
    lead.get_by_role("button", name="Reconciliation").click()
    lead.get_by_label("Stage").select_option("ft")
    lead.get_by_role("button", name=re.compile("Open reconciliation")).click(); status(lead, "Reconciliation opened")
    expect(lead.get_by_role("heading", name="Conflicts (0)")).to_be_visible(timeout=15000)
    lead.wait_for_timeout(1500)

    # ---- Extraction: lead defines the form, Ana enters (with Claude's suggestion), Bruno checks.
    lead.get_by_role("button", name="Data extraction").click()
    lead.get_by_label(re.compile("Outcomes, one per line")).fill("Pain on injection | continuous | end of block | VAS mm\nFlap necrosis | binary | 30 days")
    lead.get_by_role("button", name="Save form").click(); status(lead, "Extraction form saved")
    ana.get_by_role("button", name="Data extraction").click()
    ana.locator(".queue button").filter(has_text=word("Zeta")).first.click()
    ana.get_by_label("Study ID (first author and year)").fill("Zeta 2023")
    ana.get_by_text("Ask Claude to suggest values").click()
    ana.get_by_role("button", name="Suggest values").click(); status(ana, "Suggested values are filled in")
    expect(ana.locator("fieldset.aidraft")).to_have_count(1)
    ana.get_by_role("button", name="Save", exact=True).click(); status(ana, "Saved")
    bruno.get_by_role("button", name="Data extraction").click()
    bruno.locator(".queue button").filter(has_text=word("Zeta")).first.click()
    bruno.get_by_role("button", name="Mark as checked").click(); status(bruno, "Marked as checked")
    ana.screenshot(path=SHOTS / "6-extraction.png", full_page=True)

    # ---- PRISMA, analysis and manuscript.
    lead.get_by_role("button", name="PRISMA").click()
    svg = lead.locator(".prisma").inner_html()
    for t in ("Records identified", "Duplicate records removed: n = 4", "Records screened: n = 9", "Reports sought for retrieval: n = 3", "Reports excluded: n = 1", "Wrong study design: n = 1", "Studies included in review: n = 2"):
        assert t in svg, t
    lead.screenshot(path=SHOTS / "7-prisma.png", full_page=True)
    lead.get_by_role("button", name="Analysis").click()
    lead.get_by_role("button", name="Realizar análise estatística").click(); status(lead, "Request saved")
    expect(lead.locator(".copybox")).to_contain_text("Realizar análise estatística do FishingMeta")
    lead.get_by_role("button", name=re.compile("Continuous data")).click()
    cont = lead.evaluate("window.__downloads.at(-1).data"); print(cont)
    assert "Zeta 2023" in cont and ",yes," in cont
    lead.screenshot(path=SHOTS / "8-analysis.png", full_page=True)
    lead.get_by_role("button", name="Manuscript").click()
    lead.get_by_role("button", name="Escrever manuscrito").click(); status(lead, "Request saved")

    # Voting is closed after reconciliation opens.
    lead.get_by_role("button", name="Reconciliation").click(); lead.get_by_label("Stage").select_option("ta")
    ana.get_by_role("button", name="Title and abstract").click()
    ana.locator(".queue button").filter(has_text=word("Gamma")).first.click()
    expect(ana.get_by_text("Voting is closed.", exact=True)).to_be_visible()
    expect(ana.locator(".revealed")).to_contain_text("Bruno")
    ana.screenshot(path=SHOTS / "4-ana-after-reveal.png", full_page=True)

    lead.get_by_role("button", name="Export").click(); lead.get_by_role("button", name="Decisions (CSV)").click()
    csv_lead = lead.evaluate("window.__downloads.at(-1).data")
    print(csv_lead.splitlines()[0]); print(next(l for l in csv_lead.splitlines() if "Gamma" in l))
    lead.get_by_role("button", name=re.compile("Included references")).click()
    ris = lead.evaluate("window.__downloads.at(-1).data")
    assert ris.count("ER  -") == 3, ris
    denied = [pg.evaluate("window.__denied") for pg in (lead, ana, bruno)]
    print("denied writes:", denied)
    lead.screenshot(path=SHOTS / "5-export.png", full_page=True)
    b.close()
print("FISHINGMETA FLOW OK")
