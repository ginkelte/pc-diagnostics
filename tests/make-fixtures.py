#!/usr/bin/env python3
"""Generate the synthetic test fixtures for tests/fixtures/.

Fixtures are data, not code: they are checked in so a reviewer can read exactly
what the suite feeds the collectors. Everything here is synthetic - no hostname,
no user name, no serial number, no dump path from the field machine (RT-05).

Run this only when the fixture shape has to change; the generated files are the
source of truth at test time.
"""
import json
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
os.makedirs(OUT, exist_ok=True)

WER_DIR = r"C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
APP_DIR = r"C:\Apps"


def write(name, payload):
    path = os.path.join(OUT, name + ".json")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=True, sort_keys=False)
        fh.write("\n")
    return path


def wer_dump_event(index, app, day, hour, minute):
    """One WER 1001 event whose signature is the .dmp path.

    The path depends only on the application, never on the event index: 173
    re-reports of the same crash must collapse onto ONE signature, which is the
    whole point of the dedupe defect (1.3). The P fields are present on purpose
    so the dump-precedence rule is exercised, not merely the dump path.
    """
    stem = app.replace(".exe", "")
    return {
        "TimeCreated": "2026-11-{:02d}T{:02d}:{:02d}:00-03:00".format(day, hour, minute),
        "Id": 1001,
        "ProviderName": "Windows Error Reporting",
        "Level": "Information",
        "Message": (
            "Faulting application name: {app}, version: 1.0.0.0. Event Name: APPCRASH."
            " Attached files: {dir}\\AppCrash_{stem}\\Report.wer.dmp"
        ).format(app=app, dir=WER_DIR, stem=stem),
        "Data": {
            "AppName": app,
            "AppPath": APP_DIR + "\\" + app,
            "P1": app,
            "P2": "1.0.0.0",
            "P3": "00000000",
        },
    }


def wer_params_event(app, version, offset, day, hour, minute):
    """No .dmp path anywhere: the signature must fall back to P1..P10."""
    return {
        "TimeCreated": "2026-11-{:02d}T{:02d}:{:02d}:00-03:00".format(day, hour, minute),
        "Id": 1001,
        "ProviderName": "Windows Error Reporting",
        "Level": "Information",
        "Message": (
            "Fault bucket , type 0. Event Name: APPCRASH. Response: Not available."
            " Cab Id: 0. Problem signature: P1: {app} P2: {version} P3: {offset}"
        ).format(app=app, version=version, offset=offset),
        "Data": {
            "AppName": app,
            "AppPath": APP_DIR + "\\" + app,
            "P1": app,
            "P2": version,
            "P3": offset,
            "P4": "",
            "P5": "",
            "P6": "",
            "P7": "",
            "P8": "",
            "P9": "",
            "P10": "",
        },
    }


def wer_plain_event(day, hour, minute):
    """Neither a dump path nor a single P field: unidentified, never dropped."""
    return {
        "TimeCreated": "2026-11-{:02d}T{:02d}:{:02d}:00-03:00".format(day, hour, minute),
        "Id": 1001,
        "ProviderName": "Windows Error Reporting",
        "Level": "Information",
        "Message": "Windows Error Reporting report queued with no diagnostics attached.",
        "Data": {},
    }


# ---------------------------------------------------------------------------
# Fixture 1: the mixed System log of defect 1.2 (317 false machine checks)
# ---------------------------------------------------------------------------
whea_system = {"fixture": "whea-mixed-system-log", "logs": {"System": [], "Application": []}}

whea_rows = []
whea_rows.append({
    "TimeCreated": "2026-10-20T08:11:02-03:00", "Id": 17,
    "ProviderName": "Microsoft-Windows-WHEA-Logger", "Level": "Warning",
    "Message": "A corrected hardware error has occurred. Component: PCI Express Root Port. Error Source: Advanced Error Reporting (PCI Express).",
    "Data": {"ErrorSource": "4", "Severity": "Corrected", "ErrorType": "PCI Express"},
})
whea_rows.append({
    "TimeCreated": "2026-10-24T21:35:41-03:00", "Id": 17,
    "ProviderName": "Microsoft-Windows-WHEA-Logger", "Level": "Warning",
    "Message": "A corrected hardware error has occurred. Component: PCI Express Root Port. Error Source: Advanced Error Reporting (PCI Express).",
    "Data": {"ErrorSource": "4", "Severity": "Corrected", "ErrorType": "PCI Express"},
})
# The false positives: same event Id, other providers.
for i in range(3):
    whea_rows.append({
        "TimeCreated": "2026-10-{:02d}T12:0{}:00-03:00".format(26 + i, i),
        "Id": 19, "ProviderName": "WindowsUpdateClient", "Level": "Information",
        "Message": "Installation Successful: Windows successfully installed the following update.",
        "Data": {"updateTitle": "2026-10 Cumulative Update (KB0000000)"},
    })
for i in range(2):
    whea_rows.append({
        "TimeCreated": "2026-10-{:02d}T06:2{}:00-03:00".format(28 + i, i),
        "Id": 18, "ProviderName": "TPM", "Level": "Information",
        "Message": "The TPM is ready for use.",
        "Data": {"TPMVersion": "2.0"},
    })
whea_rows.append({
    "TimeCreated": "2026-11-02T03:04:05-03:00", "Id": 51,
    "ProviderName": "disk", "Level": "Warning",
    "Message": "An error was detected on device \\Device\\Harddisk1\\DR1 during a paging operation.",
    "Data": {"param1": "\\Device\\Harddisk1\\DR1"},
})
whea_system["logs"]["System"] = whea_rows
write("whea-mixed-system-log", whea_system)

# ---------------------------------------------------------------------------
# Fixture 2: T03 source that ignores the provider filter
# ---------------------------------------------------------------------------
offprov = {"fixture": "offprovider-source", "logs": {"System": [{
    "TimeCreated": "2026-11-05T09:00:00-03:00", "Id": 19,
    "ProviderName": "WindowsUpdateClient", "Level": "Information",
    "Message": "Installation Successful: update installed.",
    "Data": {"updateTitle": "2026-11 Cumulative Update (KB0000000)"},
}]}}
write("offprovider-source", offprov)

# ---------------------------------------------------------------------------
# Fixture 3: dump A x173 plus 11 distinct dumps (the dedupe defect, 1.3)
# ---------------------------------------------------------------------------
events = []
for i in range(173):
    events.append(wer_dump_event(i, "dumpA.exe", 3, 4 + (i % 8), i % 60))
for i, letter in enumerate("BCDEFGHIJKL"):
    events.append(wer_dump_event(200 + i, "dump{}.exe".format(letter), 6, 5 + i, i))
events.sort(key=lambda e: e["TimeCreated"])
write("wer-repeated-dump", {"fixture": "wer-repeated-dump", "logs": {"Application": events}})
print("wer-repeated-dump events:", len(events))

# ---------------------------------------------------------------------------
# Fixture 4: the RT-04 matrix shape (A x173, B x2, C x1, D x1)
# ---------------------------------------------------------------------------
events = []
for i in range(173):
    events.append(wer_dump_event(i, "dumpA.exe", 4, 4 + (i % 8), i % 60))
for i in range(2):
    events.append(wer_dump_event(300 + i, "dumpB.exe", 7, 6, i))
events.append(wer_dump_event(310, "dumpC.exe", 8, 7, 0))
events.append(wer_dump_event(320, "dumpD.exe", 9, 8, 0))
events.sort(key=lambda e: e["TimeCreated"])
write("wer-repeated-dump-matrix", {"fixture": "wer-repeated-dump-matrix", "logs": {"Application": events}})
print("wer-repeated-dump-matrix events:", len(events))

# ---------------------------------------------------------------------------
# Fixture 5: no dump path, two distinct P1..P10 groups
# ---------------------------------------------------------------------------
events = []
for i in range(4):
    events.append(wer_params_event("alpha.exe", "2.1.0.0", "0x00000001", 10, 10, i))
for i in range(2):
    events.append(wer_params_event("beta.exe", "3.4.5.6", "0x00000002", 11, 11, i * 5))
write("wer-params-only", {"fixture": "wer-params-only", "logs": {"Application": events}})

# ---------------------------------------------------------------------------
# Fixture 6: no signature at all
# ---------------------------------------------------------------------------
events = [wer_plain_event(12, 12, 0), wer_plain_event(12, 12, 30), wer_plain_event(13, 13, 0)]
write("wer-no-signature", {"fixture": "wer-no-signature", "logs": {"Application": events}})

# ---------------------------------------------------------------------------
# Fixture 7: all three signature kinds in one set
# ---------------------------------------------------------------------------
events = [
    wer_dump_event(400, "dumpM.exe", 14, 9, 0),
    wer_dump_event(401, "dumpM.exe", 14, 9, 5),
    wer_params_event("gamma.exe", "1.2.3.4", "0x00000003", 15, 9, 0),
    wer_params_event("gamma.exe", "1.2.3.4", "0x00000003", 15, 9, 10),
    wer_plain_event(16, 9, 0),
]
write("wer-mixed-signatures", {"fixture": "wer-mixed-signatures", "logs": {"Application": events}})

# ---------------------------------------------------------------------------
# Fixture 8: Spanish message bodies, identical providers, ids and counts as
# fixture 1. Classification must be byte-for-byte identical (EC-05).
# ---------------------------------------------------------------------------
ES_MESSAGES = {
    17: "Se ha producido un error de hardware corregido. Componente: puerto raiz PCI Express.",
    19: "Instalacion correcta: Windows instalo la siguiente actualizacion.",
    18: "El TPM esta listo para su uso.",
    51: "Se detecto un error en el dispositivo durante una operacion de paginacion.",
}
ES_LEVELS = {17: "Advertencia", 19: "Informacion", 18: "Informacion", 51: "Advertencia"}
es_rows = []
for row in whea_rows:
    translated = dict(row)
    translated["Message"] = ES_MESSAGES[row["Id"]]
    translated["Level"] = ES_LEVELS[row["Id"]]
    es_rows.append(translated)
write("whea-spanish-messages", {"fixture": "whea-spanish-messages", "logs": {"System": es_rows}})

print("fixtures written to", OUT)


# ---------------------------------------------------------------------------
# State fixtures (section 7 contract). Static on purpose: these three files test
# STRUCTURE, never a time comparison, so a fixed date cannot age out.
# ---------------------------------------------------------------------------
COUNTER_KEYS = [
    "whea_17", "whea_18", "whea_19", "whea_47", "stornvme_129", "disk_7",
    "disk_11", "disk_51", "disk_153", "tdr_4101", "tdr_4104",
    "kernel_power_41", "eventlog_6005", "eventlog_6006", "eventlog_6008",
    "app_error_1000", "wer_1001", "app_hang_1002", "dotnet_1026",
]

state = {
    "schema_version": 1,
    "last_run_at": "2026-11-12T21:10:00-03:00",
    "last_run_mode": "Full",
    "host": "TEST-HOST",
    "window_days": 30,
    "elevated": True,
    "off_provider_dropped": 0,
    "counters": dict((key, 0) for key in COUNTER_KEYS),
    "wer": {
        "events_seen": 184,
        "unique_dumps": 12,
        "unique_params": 0,
        "unidentified": 0,
        "repeats": 172,
        "signatures": [],
    },
    "volumes": [],
    "nvme": [],
    "boots": {"clean": 3, "dirty": 0},
    "fast_startup": True,
    "dynamic_lighting": "not_present",
    "windows": {"caption": "Windows 11 Pro", "build": "10.0.22631"},
}
write("state-v1", state)

missing_volumes = dict(state)
del missing_volumes["volumes"]
write("state-missing-volumes", missing_volumes)

newer = dict(state)
newer["schema_version"] = 2
write("state-schema-2", newer)

with open(os.path.join(OUT, "state-corrupt.json"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write('{\n  "schema_version": 1,\n  "last_run_at": "2026-11-12T21:10:00-03:00",\n  "counters": {\n')

print("state fixtures written to", OUT)
