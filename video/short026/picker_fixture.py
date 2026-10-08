"""Fictional on-disk directory for the genuine promo attachment picker.
All visible hero rows match the typed ERUPTION filter; control entries do not.
This is media/test tooling and never part of the installed application.
"""
from pathlib import Path
import hashlib
QUERY = "ERUPTION"
SELECTED = "eruption-notes.md"
NOTES = b"# A tiny eruption\nFictional launch notes only.\n"
FILES = (
    (SELECTED, 47),
    ("eruption-outline.txt", 3200),
    ("eruption-photo.png", None),
    ("eruption-readme.html", 6400),
    ("eruption-report.pdf", 183200),
    ("eruption-route.geojson", 2600),
    ("eruption-samples.csv", 24800),
    ("eruption-schedule.ics", 1600),
    ("eruption-summary.json", 8200),
    ("eruption-visuals.zip", 912400),
)
CONTROLS = ("launch-checklist.txt", "volcano-sketch.txt")
def create(directory, repo):
    documents = Path(directory) / "Documents"
    documents.mkdir(exist_ok=True)
    manifest = []
    for name, size in FILES:
        if name == SELECTED:
            payload = NOTES
        elif name.endswith(".png"):
            payload = (Path(repo) / "assets/omagma-logo.png").read_bytes()
        else:
            # Safe listing-only synthetic bytes. The film shows real file
            # names/stat sizes; it does not claim these other files were opened.
            header = ("Fictional " + name + " listing fixture.\n").encode()
            payload = header + b"0" * (size - len(header))
        path = documents / name
        path.write_bytes(payload)
        manifest.append({"filename":name,"bytes":len(payload),"sha256":hashlib.sha256(payload).hexdigest()})
    for name in CONTROLS:
        (documents / name).write_text("Nonmatching fictional filter-control file.\n")
    assert len(NOTES) == 47 and len(manifest) == 10
    assert all(QUERY.casefold() in item["filename"].casefold() for item in manifest)
    assert all(QUERY.casefold() not in name.casefold() for name in CONTROLS)
    return manifest

def record(rec):
    """Actual native filtering and focus; preserve the query in the hero."""
    rec.press("A", "picker:open")
    rec.wait(lambda: "Attach file ·" in rec.text() and "Path:" in rec.text(), name="picker:opened")
    rec.press(b"\x15Documents/", "picker:path", show=False)
    rec.gap(.10)
    rec.press(b"\r", "picker:folder")
    rec.wait(lambda: all(name in rec.text() for name in CONTROLS), name="picker:unfiltered-controls")
    rec.press(b"\x15" + ("Documents/" + QUERY).encode(), "picker:filter", show=False)
    rec.wait(lambda: all(name in rec.text() for name, _ in FILES) and all(name not in rec.text() for name in CONTROLS),
             name="picker:matching-list")
    rec.press(b"\t\t\t\t", "picker:listing-focus", show=False)
    rec.gap(.12)
    rec.wait(lambda: "Path: Documents/" + QUERY in rec.text() and SELECTED in rec.text(), name="picker:query-retained")
    column, row = rec.locate(SELECTED)
    # Native selected-row styling must be present, not an editorial highlight.
    assert rec.screen.styles[row][column][1] is not None, "first matching file lacks native selection background"
    rec.mark("picker")
    lines = rec.screen.lines()
    visible = [name for name, _ in FILES if any(name in line for line in lines)]
    assert len(visible) == 10 and all(QUERY.casefold() in name.casefold() for name in visible)
    return {"query":"Documents/" + QUERY,"matchFragment":QUERY,"visibleFilenames":visible,
            "selectedFilename":SELECTED,"selectionRow":row,"nonmatchingControlsHidden":all(name not in rec.text() for name in CONTROLS)}

def attach_selected(rec):
    # Resolve the first selected entry only after the recorded filter hero.
    rec.press(b"\x10", "picker:resolve-selected", show=False)
    rec.wait(lambda: "Path: Documents/" + SELECTED in rec.text())
    rec.press(b"\r", "picker:choose")
    rec.wait(lambda: "Attachments 1" in rec.text() and "Attach file ·" not in rec.text(), name="attached", seconds=5)
