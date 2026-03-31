#!/usr/bin/env python3

import argparse
import json
import sys

from query_safe_batch_utils import (
    DEFAULT_CHAIN_ID,
    DEFAULT_CREATE_CALL,
    DEFAULT_VANITY_MARKET,
    abi_encode,
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
        description="Generate a Safe Transaction Builder batch for a vanity PanopticQuery proxy deployment."
    )
    parser.add_argument("--deployment-safe", required=True)
    parser.add_argument("--upgrade-safe", required=True)
    parser.add_argument("--proxy-address", required=True)
    parser.add_argument("--proxy-salt", required=True)
    parser.add_argument("--proxy-nonce", type=int, default=0)
    parser.add_argument("--salt-owner")
    parser.add_argument("--mint", action="store_true")
    parser.add_argument("--chain-id", default=DEFAULT_CHAIN_ID)
    parser.add_argument("--create-call", default=DEFAULT_CREATE_CALL)
    parser.add_argument("--vanity-market", default=DEFAULT_VANITY_MARKET)
    parser.add_argument("--implementation-salt")
    parser.add_argument("--proxy-admin-salt")
    parser.add_argument(
        "--output",
        default="safe-txns/query_proxy_deploy.json",
        help="Path to the Safe Transaction Builder JSON file to write.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.proxy_nonce < 0 or args.proxy_nonce > 255:
        raise ValueError("--proxy-nonce must fit in uint8")

    root = repo_root()
    panoptic_query_artifact = root / "out/PanopticQuery.sol/PanopticQuery.json"
    proxy_admin_artifact = (
        root / "out/PanopticQueryProxyAdmin.sol/PanopticQueryProxyAdmin.json"
    )
    transparent_proxy_artifact = (
        root
        / "out/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
    )

    implementation_initcode = load_bytecode(panoptic_query_artifact)
    proxy_admin_creation_code = load_bytecode(proxy_admin_artifact)
    transparent_proxy_creation_code = load_bytecode(transparent_proxy_artifact)

    proxy_address = checksum(args.proxy_address)
    deployment_safe = checksum(args.deployment_safe)
    upgrade_safe = checksum(args.upgrade_safe)
    salt_owner = checksum(args.salt_owner or deployment_safe)
    create_call = checksum(args.create_call)
    vanity_market = checksum(args.vanity_market)
    proxy_salt = normalize_hex(args.proxy_salt)

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

    implementation_address = create2_address(
        create_call, implementation_salt, implementation_initcode
    )
    proxy_admin_address = create2_address(
        create_call, proxy_admin_salt, proxy_admin_initcode
    )

    proxy_constructor_args = abi_encode(
        "constructor(address,address,bytes)",
        implementation_address,
        proxy_admin_address,
        "0x",
    )
    proxy_initcode = (
        transparent_proxy_creation_code + proxy_constructor_args.removeprefix("0x")
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
                "deploymentData": proxy_admin_initcode,
                "salt": proxy_admin_salt,
            },
        ),
    ]

    if args.mint:
        transactions.append(
            safe_transaction(
                vanity_market,
                "mint",
                [
                    {"internalType": "address", "name": "to", "type": "address"},
                    {"internalType": "uint256", "name": "id", "type": "uint256"},
                    {"internalType": "uint8", "name": "nonce", "type": "uint8"},
                ],
                {
                    "to": salt_owner,
                    "id": str(int(proxy_salt, 16)),
                    "nonce": str(args.proxy_nonce),
                },
            )
        )

    transactions.append(
        safe_transaction(
            vanity_market,
            "deploy",
            [
                {"internalType": "uint256", "name": "id", "type": "uint256"},
                {"internalType": "bytes", "name": "initcode", "type": "bytes"},
            ],
            {
                "id": str(int(proxy_salt, 16)),
                "initcode": proxy_initcode,
            },
            payable=True,
        )
    )

    output_path = root / args.output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "chainId": str(args.chain_id),
        "meta": {
            "name": f"Deploy PanopticQuery vanity proxy at {proxy_address}",
            "description": (
                f"Deploy implementation and ProxyAdmin from {deployment_safe}, "
                f"deploy vanity proxy at {proxy_address}, with ProxyAdmin owned "
                f"by {upgrade_safe}."
            ),
        },
        "transactions": transactions,
    }

    with output_path.open("w") as file:
        json.dump(payload, file)

    print(f"Wrote Safe batch to {output_path}")
    print(f"Deployment safe: {deployment_safe}")
    print(f"Upgrade safe: {upgrade_safe}")
    print(f"Vanity proxy: {proxy_address}")
    print(f"PanopticQuery implementation: {implementation_address}")
    print(f"ProxyAdmin: {proxy_admin_address}")
    print(f"Implementation CREATE2 salt: {implementation_salt}")
    print(f"ProxyAdmin CREATE2 salt: {proxy_admin_salt}")
    if args.mint:
        print(f"Vanity slot will be minted to: {salt_owner}")
    else:
        print("Vanity mint step omitted")

    return 0


if __name__ == "__main__":
    sys.exit(main())
