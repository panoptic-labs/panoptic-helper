import json
import shlex
import subprocess
from pathlib import Path


DEFAULT_CHAIN_ID = "1"
DEFAULT_CREATE_CALL = "0x9b35Af71d77eaf8d7e40252370304687390A1A52"
DEFAULT_VANITY_MARKET = "0x000000000000b361194cfe6312EE3210d53C15AA"


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run_cast(*args: str) -> str:
    result = subprocess.run(
        ["cast", *args], check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


def normalize_hex(value: str) -> str:
    if value.startswith("0x"):
        return value
    return "0x" + value


def checksum(address: str) -> str:
    return run_cast("to-check-sum-address", address)


def keccak_hex(data: str) -> str:
    return run_cast("keccak", normalize_hex(data))


def keccak_text(text: str) -> str:
    return keccak_hex(text.encode().hex())


def abi_encode(signature: str, *values: str) -> str:
    return run_cast("abi-encode", signature, *values)


def load_bytecode(path: Path) -> str:
    with path.open() as file:
        artifact = json.load(file)
    return normalize_hex(artifact["bytecode"]["object"])


def load_artifact(path: Path) -> dict:
    with path.open() as file:
        return json.load(file)


def create2_address(deployer: str, salt: str, initcode: str) -> str:
    initcode_hash = keccak_hex(initcode)
    packed = (
        "ff"
        + deployer.lower().removeprefix("0x")
        + normalize_hex(salt).lower().removeprefix("0x")
        + initcode_hash.lower().removeprefix("0x")
    )
    derived = keccak_hex(packed)
    return checksum("0x" + derived[-40:])


def safe_transaction(
    to: str,
    method_name: str,
    inputs: list[dict],
    values: dict[str, str],
    *,
    payable: bool = False,
    value: str = "0",
) -> dict:
    return {
        "to": checksum(to),
        "value": value,
        "data": None,
        "contractMethod": {
            "inputs": inputs,
            "name": method_name,
            "payable": payable,
        },
        "contractInputsValues": values,
    }


def shell_join(parts: list[str]) -> str:
    return shlex.join(parts)
