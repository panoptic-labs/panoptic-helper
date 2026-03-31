#!/usr/bin/env python3

import argparse
import json
import sys

from query_safe_batch_utils import (
    DEFAULT_CHAIN_ID,
    DEFAULT_CREATE_CALL,
    checksum,
    create2_address,
    keccak_text,
    load_bytecode,
    normalize_hex,
    repo_root,
    safe_transaction,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a Safe Transaction Builder batch for upgrading a PanopticQuery vanity proxy."
    )
    parser.add_argument("--upgrade-safe", required=True)
    parser.add_argument("--proxy-address", required=True)
    parser.add_argument("--proxy-admin", required=True)
    parser.add_argument("--implementation-salt")
    parser.add_argument("--version-label")
    parser.add_argument("--chain-id", default=DEFAULT_CHAIN_ID)
    parser.add_argument("--create-call", default=DEFAULT_CREATE_CALL)
    parser.add_argument(
        "--output",
        default="safe-txns/query_proxy_upgrade.json",
        help="Path to the Safe Transaction Builder JSON file to write.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    root = repo_root()
    panoptic_query_artifact = root / "out/PanopticQuery.sol/PanopticQuery.json"

    implementation_initcode = load_bytecode(panoptic_query_artifact)

    proxy_address = checksum(args.proxy_address)
    proxy_admin = checksum(args.proxy_admin)
    upgrade_safe = checksum(args.upgrade_safe)
    create_call = checksum(args.create_call)

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
        create_call, implementation_salt, implementation_initcode
    )

    transactions = [
        safe_transaction(
            create_call,
            "performCreate2",
            [
                {"internalType": "uint256", "name": "value", "type": "uint256"},
                {
                    "internalType": "bytes",
                    "name": "deploymentData",
                    "type": "bytes",
                },
                {"internalType": "bytes32", "name": "salt", "type": "bytes32"},
            ],
            {
                "value": "0",
                "deploymentData": implementation_initcode,
                "salt": implementation_salt,
            },
        ),
        safe_transaction(
            proxy_admin,
            "upgrade",
            [
                {"internalType": "contract ITransparentUpgradeableProxy", "name": "proxy", "type": "address"},
                {"internalType": "address", "name": "implementation", "type": "address"},
            ],
            {
                "proxy": proxy_address,
                "implementation": implementation_address,
            },
        ),
    ]

    output_path = root / args.output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "chainId": str(args.chain_id),
        "meta": {
            "name": f"Upgrade PanopticQuery proxy at {proxy_address}",
            "description": (
                f"Deploy a new PanopticQuery implementation from {upgrade_safe} "
                f"and upgrade proxy {proxy_address} via ProxyAdmin {proxy_admin}."
            ),
        },
        "transactions": transactions,
    }

    with output_path.open("w") as file:
        json.dump(payload, file)

    print(f"Wrote Safe batch to {output_path}")
    print(f"Upgrade safe: {upgrade_safe}")
    print(f"PanopticQuery proxy: {proxy_address}")
    print(f"ProxyAdmin: {proxy_admin}")
    print(f"New implementation: {implementation_address}")
    print(f"Implementation CREATE2 salt: {implementation_salt}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
