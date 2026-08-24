@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul

set PYTHONDONTWRITEBYTECODE=1
python -c "import pathlib, sys; path = pathlib.Path(sys.argv[1]); text = path.read_text(encoding='utf-8'); marker = '### PYTHON_SCRIPT_START ###\n'; code = text.split(marker, 1)[1]; sys.argv = [str(path)] + sys.argv[2:]; exec(compile(code, str(path), 'exec'))" "%~f0" --format collection

if errorlevel 1 (
    echo.
    pause
    exit /b 1
)

echo.
pause
exit /b 0

### PYTHON_SCRIPT_START ###
import sys

sys.dont_write_bytecode = True

import argparse
import base64
import csv
import ctypes
import json
import ssl
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_LOCKFILE_PATHS = [
    Path(r"C:\Riot Games\League of Legends\lockfile"),
    Path(r"C:\Program Files\Riot Games\League of Legends\lockfile"),
    Path(r"C:\Program Files (x86)\Riot Games\League of Legends\lockfile"),
]


MESSAGES = {
    "en": {
        "lockfile_missing": (
            "Export failed. League Client was not found. "
            "Open League of Legends, log in, and try again."
        ),
        "http_error": "Export failed. League Client returned HTTP error {code}.",
        "connection_error": (
            "Export failed. Could not connect to League Client. "
            "Make sure it is open and you are logged in. Details: {error}"
        ),
        "generic_error": "Export failed. Details: {error}",
        "copied": "Export completed. The collection has been copied to the clipboard.",
    },
    "es": {
        "lockfile_missing": (
            "La exportación ha fallado. No se ha encontrado el cliente de League of Legends. "
            "Abre el juego, inicia sesión y vuelve a intentarlo."
        ),
        "http_error": "La exportación ha fallado. El cliente de League of Legends devolvió el error HTTP {code}.",
        "connection_error": (
            "La exportación ha fallado. No se ha podido conectar con el cliente de League of Legends. "
            "Comprueba que esté abierto y que hayas iniciado sesión. Detalles: {error}"
        ),
        "generic_error": "La exportación ha fallado. Detalles: {error}",
        "copied": "Exportación completada. La colección se ha copiado al portapapeles.",
    },
}


def system_language():
    try:
        locale_name = ctypes.create_unicode_buffer(85)
        if ctypes.windll.kernel32.GetUserDefaultLocaleName(locale_name, len(locale_name)):
            return "es" if locale_name.value.lower().startswith("es") else "en"
    except (AttributeError, OSError):
        pass

    return "en"


LANGUAGE = system_language()


def message(key, **values):
    return MESSAGES[LANGUAGE][key].format(**values)


def find_lockfile(custom_path=None):
    if custom_path:
        path = Path(custom_path)
        return path if path.is_file() else None

    for path in DEFAULT_LOCKFILE_PATHS:
        if path.is_file():
            return path

    return None


def read_lockfile(path):
    content = path.read_text(encoding="utf-8").strip()
    parts = content.split(":")

    if len(parts) != 5:
        raise ValueError(f"Invalid lockfile format: {path}")

    name, pid, port, password, protocol = parts
    return {
        "name": name,
        "pid": pid,
        "port": port,
        "password": password,
        "protocol": protocol,
    }


def lcu_get(lockfile_data, endpoint):
    auth = base64.b64encode(f"riot:{lockfile_data['password']}".encode("utf-8")).decode("ascii")
    url = f"{lockfile_data['protocol']}://127.0.0.1:{lockfile_data['port']}{endpoint}"
    request = Request(url, headers={"Authorization": f"Basic {auth}"})
    context = ssl._create_unverified_context()

    with urlopen(request, context=context, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def normalize_purchase_date(value):
    if value in (None, "", 0):
        return None

    if isinstance(value, (int, float)):
        timestamp = value / 1000 if value > 10_000_000_000 else value
        return datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime("%Y-%m-%d")

    text = str(value).strip()
    if not text:
        return None

    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).strftime("%Y-%m-%d")
    except ValueError:
        return text


def skin_id_from_item(skin):
    for key in ("itemId", "skinId", "id"):
        value = skin.get(key)
        if value not in (None, ""):
            return str(value)

    return None


def is_owned_skin(skin):
    ownership_type = str(skin.get("ownershipType", "")).upper()
    if ownership_type in {"OWNED", "RENTAL", "FREE", "F2P"}:
        return True

    if skin.get("owned") is True:
        return True

    if skin.get("purchaseDate"):
        return True

    return False


def to_collection_json(skins, owned_only=True):
    collection = {}

    for skin in skins:
        skin_id = skin_id_from_item(skin)
        if not skin_id:
            continue

        owned = is_owned_skin(skin)
        if owned_only and not owned:
            continue

        acquired_date = normalize_purchase_date(skin.get("purchaseDate"))
        collection[skin_id] = acquired_date or datetime.now().strftime("%m/%d/%Y")

    return collection


def copy_to_clipboard(text):
    cf_unicode_text = 13
    gmem_moveable = 0x0002
    encoded = (text + "\0").encode("utf-16-le")

    kernel32 = ctypes.windll.kernel32
    user32 = ctypes.windll.user32
    kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalFree.argtypes = [ctypes.c_void_p]
    user32.OpenClipboard.argtypes = [ctypes.c_void_p]
    user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    user32.SetClipboardData.restype = ctypes.c_void_p

    memory = kernel32.GlobalAlloc(gmem_moveable, len(encoded))
    if not memory:
        raise ctypes.WinError()

    clipboard_owns_memory = False
    try:
        pointer = kernel32.GlobalLock(memory)
        if not pointer:
            raise ctypes.WinError()

        try:
            ctypes.memmove(pointer, encoded, len(encoded))
        finally:
            kernel32.GlobalUnlock(memory)

        if not user32.OpenClipboard(None):
            raise ctypes.WinError()

        try:
            if not user32.EmptyClipboard():
                raise ctypes.WinError()
            if not user32.SetClipboardData(cf_unicode_text, memory):
                raise ctypes.WinError()
            clipboard_owns_memory = True
        finally:
            user32.CloseClipboard()
    finally:
        if not clipboard_owns_memory:
            kernel32.GlobalFree(memory)


def copy_json_to_clipboard(data):
    text = json.dumps(data, ensure_ascii=False, indent=2)
    copy_to_clipboard(text)


def print_table(skins):
    rows = []
    for skin in skins:
        rows.append([
            skin_id_from_item(skin) or "",
            skin.get("name") or skin.get("itemName") or "",
            skin.get("ownershipType") or "",
            normalize_purchase_date(skin.get("purchaseDate")) or "",
        ])

    widths = [8, 42, 16, 14]
    print(f"{'Skin ID':<{widths[0]}} {'Name':<{widths[1]}} {'Ownership':<{widths[2]}} {'Purchase Date':<{widths[3]}}")
    print("-" * sum(widths) + "-" * 3)
    for skin_id, name, ownership, purchase_date in rows:
        print(f"{skin_id:<{widths[0]}} {name[:widths[1] - 1]:<{widths[1]}} {ownership:<{widths[2]}} {purchase_date:<{widths[3]}}")


def write_csv(skins, output_path):
    fieldnames = ["skin_id", "name", "ownership_type", "purchase_date"]

    if output_path:
        handle = Path(output_path).open("w", newline="", encoding="utf-8")
        close_handle = True
    else:
        handle = sys.stdout
        close_handle = False

    try:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for skin in skins:
            writer.writerow({
                "skin_id": skin_id_from_item(skin) or "",
                "name": skin.get("name") or skin.get("itemName") or "",
                "ownership_type": skin.get("ownershipType") or "",
                "purchase_date": normalize_purchase_date(skin.get("purchaseDate")) or "",
            })
    finally:
        if close_handle:
            handle.close()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Export owned League of Legends skins from the local League Client API."
    )
    parser.add_argument("--lockfile", help="Custom path to League Client lockfile.")
    parser.add_argument(
        "--format",
        choices=["collection", "raw", "table", "csv"],
        default="collection",
        help="Output format. 'collection' works with this League Of Collection app.",
    )
    parser.add_argument(
        "--include-unowned",
        action="store_true",
        help="Only used with --format collection. Include unowned entries if the LCU returns them.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    lockfile_path = find_lockfile(args.lockfile)

    if not lockfile_path:
        print(message("lockfile_missing"), file=sys.stderr)
        return 1

    try:
        lockfile_data = read_lockfile(lockfile_path)
        skins = lcu_get(lockfile_data, "/lol-inventory/v2/inventory/CHAMPION_SKIN")
    except HTTPError as error:
        print(message("http_error", code=error.code), file=sys.stderr)
        return 1
    except (URLError, TimeoutError) as error:
        print(message("connection_error", error=error), file=sys.stderr)
        return 1
    except Exception as error:
        print(message("generic_error", error=error), file=sys.stderr)
        return 1

    if args.format == "raw":
        copy_json_to_clipboard(skins)
    elif args.format == "collection":
        collection = to_collection_json(skins, owned_only=not args.include_unowned)
        copy_json_to_clipboard(collection)
    elif args.format == "csv":
        write_csv(skins, None)
    else:
        print_table(skins)

    if args.format in {"raw", "collection"}:
        print(message("copied"))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
