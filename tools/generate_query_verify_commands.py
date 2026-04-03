#!/usr/bin/env python3

import argparse
import json
import sys

from query_safe_batch_utils import (
    DEFAULT_CREATE_CALL,
    abi_encode,
    checksum,
    create2_address,
    keccak_text,
    load_artifact,
    load_bytecode,
    normalize_hex,
    repo_root,
    shell_join,
)


def build_verify_command(
    address: str,
    contract_identifier: str,
    compiler_version: str,
    constructor_args: str | None = None,
) -> str:
    command = [
        "forge",
        "verify-contract",
        "--chain",
        "mainnet",
        "--verifier",
        "etherscan",
        "--etherscan-api-key",
        "$ETHERSCAN_API_KEY",
        "--watch",
        "--compiler-version",
        compiler_version,
    ]

    if constructor_args is not None:
        command.extend(["--constructor-args", constructor_args])

    command.extend([address, contract_identifier])
    return shell_join(command)


def contract_identifier(artifact: dict) -> str:
    target = artifact["metadata"]["settings"]["compilationTarget"]
    [(source_path, contract_name)] = target.items()
    return f"{source_path}:{contract_name}"


def compiler_version(artifact: dict) -> str:
    return "v" + artifact["metadata"]["compiler"]["version"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate forge verify-contract commands for a PanopticQuery deployment or upgrade."
    )
    parser.add_argument("--proxy-address", required=True)
    parser.add_argument(
        "--mode",
        choices=["deploy", "upgrade"],
        required=True,
        help="Whether to generate verification commands for the initial deployment or for an upgrade.",
    )
    parser.add_argument("--upgrade-safe")
    parser.add_argument("--proxy-admin")
    parser.add_argument("--implementation")
    parser.add_argument("--implementation-salt")
    parser.add_argument("--proxy-admin-salt")
    parser.add_argument("--version-label")
    parser.add_argument("--create-call", default=DEFAULT_CREATE_CALL)
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    root = repo_root()
    panoptic_query_artifact = load_artifact(root / "out/PanopticQuery.sol/PanopticQuery.json")
    proxy_admin_artifact = load_artifact(
        root / "out/PanopticQueryProxyAdmin.sol/PanopticQueryProxyAdmin.json"
    )
    transparent_proxy_artifact = load_artifact(
        root / "out/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
    )

    panoptic_query_bytecode = normalize_hex(
        panoptic_query_artifact["bytecode"]["object"]
    )
    proxy_admin_creation_code = normalize_hex(
        proxy_admin_artifact["bytecode"]["object"]
    )

    proxy_address = checksum(args.proxy_address)
    create_call = checksum(args.create_call)

    if args.mode == "deploy":
        if args.upgrade_safe is None:
            raise ValueError("--upgrade-safe is required in deploy mode")

        upgrade_safe = checksum(args.upgrade_safe)
        implementation_salt = normalize_hex(
            args.implementation_salt
            or keccak_text(f"panoptic-query-implementation:{proxy_address.lower()}")
        )
        proxy_admin_salt = normalize_hex(
            args.proxy_admin_salt
            or keccak_text(f"panoptic-query-proxy-admin:{proxy_address.lower()}")
        )
        proxy_admin_initcode = (
            proxy_admin_creation_code
            + abi_encode("constructor(address)", upgrade_safe).removeprefix("0x")
        )
        implementation_address = checksum(
            args.implementation
            or create2_address(create_call, implementation_salt, panoptic_query_bytecode)
        )
        proxy_admin_address = checksum(
            args.proxy_admin
            or create2_address(create_call, proxy_admin_salt, proxy_admin_initcode)
        )

        proxy_constructor_args = abi_encode(
            "constructor(address,address,bytes)",
            implementation_address,
            proxy_admin_address,
            "0x",
        )
        proxy_admin_constructor_args = abi_encode(
            "constructor(address)", upgrade_safe
        )

        print("# Initial deployment verification")
        print("# Set ETHERSCAN_API_KEY before running these commands.")
        print()
        print(
            "# PanopticQuery implementation:",
            implementation_address,
        )
        print(
            build_verify_command(
                implementation_address,
                contract_identifier(panoptic_query_artifact),
                compiler_version(panoptic_query_artifact),
            )
        )
        print()
        print("# PanopticQueryProxyAdmin:", proxy_admin_address)
        print(
            build_verify_command(
                proxy_admin_address,
                contract_identifier(proxy_admin_artifact),
                compiler_version(proxy_admin_artifact),
                proxy_admin_constructor_args,
            )
        )
        print()
        print("# TransparentUpgradeableProxy:", proxy_address)
        print(
            build_verify_command(
                proxy_address,
                contract_identifier(transparent_proxy_artifact),
                compiler_version(transparent_proxy_artifact),
                proxy_constructor_args,
            )
        )
        return 0

    if args.implementation is not None:
        implementation_address = checksum(args.implementation)
    else:
        if args.implementation_salt is not None:
            implementation_salt = normalize_hex(args.implementation_salt)
        else:
            version_label = args.version_label or "default"
            implementation_salt = normalize_hex(
                keccak_text(
                    f"panoptic-query-upgrade:{proxy_address.lower()}:{version_label}"
                )
            )
        implementation_address = create2_address(
            create_call,
            implementation_salt,
            panoptic_query_bytecode,
        )

    print("# Upgrade verification")
    print("# Only the new implementation needs Etherscan verification on upgrades.")
    print()
    print("# PanopticQuery implementation:", implementation_address)
    print(
        build_verify_command(
            implementation_address,
            contract_identifier(panoptic_query_artifact),
            compiler_version(panoptic_query_artifact),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
