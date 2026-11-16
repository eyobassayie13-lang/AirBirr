import base64
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile
import threading
import time
import sys
from typing import Any, Dict, Tuple
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
import uvicorn

# Ensure parent directory is in sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

# Temporary test directory for isolated database and seed key
TEST_DIR = Path(tempfile.mkdtemp(prefix="offpay_backend_test_"))
TEST_DB_PATH = TEST_DIR / "master_bank_test.db"
TEST_KEY_SEED_PATH = TEST_DIR / "bank_master_key_test.seed"

os.environ.pop("DATABASE_URL", None)
os.environ.pop("BANK_MASTER_SEED", None)
os.environ["OFFPAY_DB_PATH"] = str(TEST_DB_PATH)
os.environ["OFFPAY_KEY_SEED_PATH"] = str(TEST_KEY_SEED_PATH)

import backend.main as bmain


def make_request(
    url: str,
    method: str = "GET",
    data: Any = None,
) -> Tuple[int, Dict[str, Any]]:
    req_data = None
    headers = {}
    if data is not None:
        req_data = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=req_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as response:
            status_code = response.status
            body = response.read().decode("utf-8")
            return status_code, json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        status_code = e.code
        body = e.read().decode("utf-8")
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"detail": body}
        return status_code, parsed


class ServerThread(threading.Thread):
    def __init__(self, app, host="127.0.0.1", port=8888):
        super().__init__(daemon=True)
        self.host = host
        self.port = port
        config = uvicorn.Config(app, host=host, port=port, log_level="warning")
        self.server = uvicorn.Server(config)

    def run(self):
        self.server.run()

    def stop(self):
        self.server.should_exit = True


def generate_test_client_keypair():
    priv = ed25519.Ed25519PrivateKey.generate()
    pub = priv.public_key()
    pub_bytes = pub.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    pub_b64 = base64.b64encode(pub_bytes).decode("utf-8")
    return priv, pub_b64


def test_suite():
    print("==================================================================")
    print("STARTING OFFPAY CENTRAL CLEARINGHOUSE BACKEND TEST SUITE")
    print("==================================================================")

    # 1. Startup & Key Initialization
    bmain.DB_PATH = TEST_DB_PATH
    bmain.KEY_SEED_PATH = TEST_KEY_SEED_PATH
    bmain.init_db(TEST_DB_PATH)
    bank_priv = bmain.load_or_generate_bank_key(TEST_KEY_SEED_PATH)
    assert TEST_KEY_SEED_PATH.exists(), "Key seed file was not persisted"

    # Reload test
    reloaded_key = bmain.load_or_generate_bank_key(TEST_KEY_SEED_PATH)
    orig_pub = bank_priv.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    reloaded_pub = reloaded_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    assert orig_pub == reloaded_pub, "Reloaded key does not match generated key"
    print("[PASS] 1. Master Bank Keypair persisted and reloaded successfully.")

    # Start FastAPI server on localhost:8888
    server_thread = ServerThread(bmain.app, host="127.0.0.1", port=8888)
    server_thread.start()
    time.sleep(1.0)  # wait for uvicorn to bind

    base_url = "http://127.0.0.1:8888"

    try:
        # 2. GET /api/v1/bank/public-key
        code, resp = make_request(f"{base_url}/api/v1/bank/public-key")
        assert code == 200, f"Expected 200, got {code}: {resp}"
        bank_pubkey_b64 = resp["public_key"]
        assert len(base64.b64decode(bank_pubkey_b64)) == 32
        print(f"[PASS] 2. Bank Public Key endpoint returned: {bank_pubkey_b64[:16]}...")

        # 3. POST /api/v1/auth/register (Customer)
        cust_priv, cust_pub_b64 = generate_test_client_keypair()
        code, cust_resp = make_request(
            f"{base_url}/api/v1/auth/register",
            method="POST",
            data={
                "account_id": "0911000001",
                "owner_name": "Almaz Kebede",
                "public_key": cust_pub_b64,
                "is_merchant": False,
            },
        )
        assert code in (200, 201), f"Expected 200/201, got {code}: {cust_resp}"
        assert cust_resp["online_balance"] == 1000000.0
        assert cust_resp["certificate"] is None
        print("[PASS] 3. Customer account registered with 1000000.0 ETB balance.")

        # 4. POST /api/v1/auth/register (Merchant with Identity Certificate)
        merch_priv, merch_pub_b64 = generate_test_client_keypair()
        code, merch_resp = make_request(
            f"{base_url}/api/v1/auth/register",
            method="POST",
            data={
                "account_id": "merchant_bole_cafe",
                "owner_name": "Bole Cafe",
                "public_key": merch_pub_b64,
                "is_merchant": True,
            },
        )
        assert code in (200, 201), f"Expected 200/201, got {code}: {merch_resp}"
        assert merch_resp["is_merchant"] is True
        assert merch_resp["certificate"] is not None

        cert = merch_resp["certificate"]
        assert cert["owner_name"] == "Bole Cafe"
        assert cert["public_key"] == merch_pub_b64

        # Mathematically verify Sign_Bank(owner_name + public_key)
        cert_msg = f"{cert['owner_name']}{cert['public_key']}".encode("utf-8")
        is_cert_valid = bmain.verify_ed25519_signature(
            bank_pubkey_b64, cert_msg, cert["signature"]
        )
        assert is_cert_valid, "Bank signature on merchant certificate failed verification!"
        print("[PASS] 4. Merchant registered and Bank Identity Certificate verified mathematically.")

        # 5. Duplicate registration check (should return 200 with already_registered)
        code, dup_resp = make_request(
            f"{base_url}/api/v1/auth/register",
            method="POST",
            data={
                "account_id": "0911000001",
                "owner_name": "Almaz Kebede",
                "public_key": cust_pub_b64,
                "is_merchant": False,
            },
        )
        assert code == 200, f"Expected 200 for duplicate, got {code}: {dup_resp}"
        assert dup_resp.get("status") == "already_registered"
        assert dup_resp.get("account_id") == "0911000001"
        assert "online_balance" in dup_resp
        print("[PASS] 5. Duplicate account registration handled idempotently with 200.")

        # 5b. GET /api/v1/accounts
        code, accounts_resp = make_request(f"{base_url}/api/v1/accounts")
        assert code == 200, f"Expected 200, got {code}: {accounts_resp}"
        assert isinstance(accounts_resp, list)
        assert len(accounts_resp) >= 2
        print(f"[PASS] 5b. GET /api/v1/accounts returned {len(accounts_resp)} registered accounts.")

        # 6. POST /api/v1/lease/issue (Success)
        code, lease_resp = make_request(
            f"{base_url}/api/v1/lease/issue",
            method="POST",
            data={
                "account_id": "0911000001",
                "amount_to_lease": 300.0,
                "duration_days": 7,
            },
        )
        assert code == 200, f"Expected 200, got {code}: {lease_resp}"
        assert lease_resp["amount_leased"] == 300.0
        assert lease_resp["remaining_online_balance"] == 999700.0

        lease_cert = lease_resp["certificate"]
        assert lease_cert["payer_pubkey"] == cust_pub_b64
        assert lease_cert["max_allowance"] == 300.0

        # Mathematically verify Bank signature over {expires_at, lease_id, max_allowance, payer_pubkey}
        lease_payload = {
            "expires_at": lease_cert["expires_at"],
            "lease_id": lease_cert["lease_id"],
            "max_allowance": 300.0,
            "payer_pubkey": cust_pub_b64,
        }
        lease_bytes = bmain.canonical_json(lease_payload).encode("utf-8")
        is_lease_valid = bmain.verify_ed25519_signature(
            bank_pubkey_b64, lease_bytes, lease_cert["signature"]
        )
        assert is_lease_valid, "Bank signature on Lease Certificate failed verification!"
        print("[PASS] 6. Offline lease issued, balance deducted to 999700.0 ETB, LeaseCertificate verified.")

        # 7. POST /api/v1/lease/issue (Insufficient balance)
        code, fail_lease = make_request(
            f"{base_url}/api/v1/lease/issue",
            method="POST",
            data={
                "account_id": "0911000001",
                "amount_to_lease": 2000000.0,  # Exceeds remaining 999700.0 balance!
                "duration_days": 7,
            },
        )
        assert code == 400, f"Expected 400 for insufficient balance, got {code}: {fail_lease}"
        print("[PASS] 7. Excessive lease request rejected with 400.")

        # 8. POST /api/v1/settlement/batch-sync (Valid Voucher)
        # Customer creates and signs an offline payment voucher for 50.0 ETB to Bole Cafe
        voucher_id = f"{cust_pub_b64}_1"
        voucher_timestamp = int(time.time())
        voucher_payload = {
            "voucher_id": voucher_id,
            "payer": cust_pub_b64,
            "payee": "Bole Cafe",
            "amount": 50.0,
            "nonce": 1,
            "timestamp": voucher_timestamp,
        }
        voucher_bytes = bmain.canonical_json(voucher_payload).encode("utf-8")
        voucher_sig = base64.b64encode(cust_priv.sign(voucher_bytes)).decode("utf-8")

        sync_item = {
            **voucher_payload,
            "signature": voucher_sig,
        }

        code, sync_resp = make_request(
            f"{base_url}/api/v1/settlement/batch-sync",
            method="POST",
            data={"vouchers": [sync_item]},
        )
        assert code == 200, f"Expected 200, got {code}: {sync_resp}"
        assert voucher_id in sync_resp["settled_voucher_ids"]
        assert sync_resp["newly_cleared_count"] == 1
        assert sync_resp["rejected_count"] == 0

        # Check Merchant online balance was credited from 1000000.0 to 1000050.0 ETB
        code, merch_acc = make_request(f"{base_url}/api/v1/accounts/merchant_bole_cafe")
        assert code == 200
        assert merch_acc["online_balance"] == 1000050.0, f"Expected 1000050.0, got {merch_acc['online_balance']}"
        assert len(merch_acc["received_vouchers"]) == 1
        assert merch_acc["received_vouchers"][0]["voucher_id"] == voucher_id
        print("[PASS] 8. Valid voucher cleared and merchant credited from 1000000.0 to 1000050.0 ETB.")

        # 9. POST /api/v1/settlement/batch-sync (Idempotency check: Re-uploading same voucher)
        code, sync_resp2 = make_request(
            f"{base_url}/api/v1/settlement/batch-sync",
            method="POST",
            data={"vouchers": [sync_item]},
        )
        assert code == 200
        assert voucher_id in sync_resp2["settled_voucher_ids"]
        assert sync_resp2["already_synced_count"] == 1
        assert sync_resp2["newly_cleared_count"] == 0

        # Verify Merchant was NOT re-credited (still 1000050.0)
        code, merch_acc2 = make_request(f"{base_url}/api/v1/accounts/merchant_bole_cafe")
        assert merch_acc2["online_balance"] == 1000050.0
        print("[PASS] 9. Idempotency verified: Duplicate voucher re-synced without double-crediting.")

        # 10. POST /api/v1/settlement/batch-sync (Tampered voucher rejected)
        tampered_item = dict(sync_item)
        tampered_item["voucher_id"] = f"{cust_pub_b64}_2"
        tampered_item["amount"] = 500.0  # Tampered amount with old signature!
        tampered_item["nonce"] = 2

        code, sync_resp3 = make_request(
            f"{base_url}/api/v1/settlement/batch-sync",
            method="POST",
            data={"vouchers": [tampered_item]},
        )
        assert code == 200
        assert sync_resp3["rejected_count"] == 1
        assert tampered_item["voucher_id"] not in sync_resp3["settled_voucher_ids"]
        print("[PASS] 10. Tampered voucher rejected mathematically without crediting.")

        # 11. POST /api/v1/settlement/batch-sync (124-byte packed binary voucher)
        # Test OffPay Rule 4 binary packing support
        cust_raw_pub = base64.b64decode(cust_pub_b64)
        payee_bytes = "Bole Cafe".encode("utf-8")[:16].ljust(16, b"\x00")
        bin_payload = struct.pack(">32s16sIII", cust_raw_pub, payee_bytes, 2500, 3, voucher_timestamp)
        assert len(bin_payload) == 60
        bin_sig = cust_priv.sign(bin_payload)
        assert len(bin_sig) == 64
        packed_voucher = bin_payload + bin_sig
        assert len(packed_voucher) == 124

        packed_sync_item = {
            "voucher_id": f"{cust_pub_b64}_3",
            "payer_pubkey": cust_pub_b64,
            "payee_id": "Bole Cafe",
            "amount": 25.0,
            "nonce": 3,
            "timestamp": voucher_timestamp,
            "raw_bytes": base64.b64encode(packed_voucher).decode("utf-8"),
            "signature": base64.b64encode(bin_sig).decode("utf-8"),
        }

        code, sync_resp4 = make_request(
            f"{base_url}/api/v1/settlement/batch-sync",
            method="POST",
            data=[packed_sync_item],  # Also tests raw list body format
        )
        assert code == 200
        assert f"{cust_pub_b64}_3" in sync_resp4["settled_voucher_ids"]
        assert sync_resp4["newly_cleared_count"] == 1

        # Check Merchant balance: 1000050.0 + 25.0 = 1000075.0 ETB
        code, merch_acc3 = make_request(f"{base_url}/api/v1/accounts/merchant_bole_cafe")
        assert merch_acc3["online_balance"] == 1000075.0
        print("[PASS] 11. 124-byte binary packed voucher verified and settled (Balance = 1000075.0 ETB).")

        # 12. GET /api/v1/accounts/{account_id} (Customer History)
        code, cust_acc = make_request(f"{base_url}/api/v1/accounts/0911000001")
        assert code == 200
        assert cust_acc["online_balance"] in (999625.0, 999700.0)
        assert len(cust_acc["sent_vouchers"]) == 2  # voucher #1 and voucher #3
        assert len(cust_acc["leases"]) == 1  # 300.0 ETB lease
        print("[PASS] 12. Customer account detail & full transaction history verified.")

        # 13. Non-existent account check (404)
        code, not_found = make_request(f"{base_url}/api/v1/accounts/unknown_account")
        assert code == 404
        print("[PASS] 13. Non-existent account returned 404.")

        # 14. Nonce collision / Replay attack detection
        collision_item = {
            "voucher_id": "different_voucher_id_replay",
            "payer_pubkey": cust_pub_b64,
            "payee_id": "Bole Cafe",
            "amount": 50.0,
            "nonce": 1,  # Nonce 1 was ALREADY used by voucher f"{cust_pub_b64}_1"
            "timestamp": voucher_timestamp,
            "signature": sync_item["signature"],
        }
        code, collision_resp = make_request(
            f"{base_url}/api/v1/settlement/batch-sync",
            method="POST",
            data={"vouchers": [collision_item]},
        )
        assert code == 200
        assert collision_resp["rejected_count"] == 1
        assert "different_voucher_id_replay" not in collision_resp["settled_voucher_ids"]
        assert any(
            r["voucher_id"] == "different_voucher_id_replay"
            and r["reason"] == "Nonce collision / Replay attack detected"
            for r in collision_resp["rejected_vouchers"]
        )
        print("[PASS] 14. Nonce collision / Replay attack detected and rejected.")

        # 15. Self-transfer filtering in sent_vouchers
        self_voucher_id = f"{cust_pub_b64}_4"
        self_payload = {
            "voucher_id": self_voucher_id,
            "payer": cust_pub_b64,
            "payee": "Almaz Kebede",  # owner_name of customer account 0911000001
            "amount": 10.0,
            "nonce": 4,
            "timestamp": voucher_timestamp,
        }
        self_sig = cust_priv.sign(
            bmain.canonical_json(self_payload).encode("utf-8")
        )
        self_sync_item = {
            "voucher_id": self_voucher_id,
            "payer_pubkey": cust_pub_b64,
            "payee_id": "Almaz Kebede",
            "amount": 10.0,
            "nonce": 4,
            "timestamp": voucher_timestamp,
            "signature": base64.b64encode(self_sig).decode("utf-8"),
        }
        code, self_sync_resp = make_request(
            f"{base_url}/api/v1/settlement/batch-sync",
            method="POST",
            data={"vouchers": [self_sync_item]},
        )
        assert code == 200
        assert f"{cust_pub_b64}_4" in self_sync_resp["settled_voucher_ids"]

        code, cust_acc_updated = make_request(f"{base_url}/api/v1/accounts/0911000001")
        assert code == 200
        received_ids = [v["voucher_id"] for v in cust_acc_updated["received_vouchers"]]
        sent_ids = [v["voucher_id"] for v in cust_acc_updated["sent_vouchers"]]
        assert f"{cust_pub_b64}_4" in received_ids
        assert f"{cust_pub_b64}_4" not in sent_ids  # Filtered out so not duplicated!
        print("[PASS] 15. Self-transfers correctly separated and excluded from sent_vouchers.")

        # 16. BANK_MASTER_SEED env var verification
        test_seed_bytes = b"01234567890123456789012345678901"  # exactly 32 bytes
        test_seed_b64 = base64.b64encode(test_seed_bytes).decode("utf-8")
        os.environ["BANK_MASTER_SEED"] = test_seed_b64
        env_key = bmain.load_or_generate_bank_key()
        expected_pub = ed25519.Ed25519PrivateKey.from_private_bytes(test_seed_bytes).public_key()
        expected_pub_b64 = base64.b64encode(
            expected_pub.public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
        ).decode("utf-8")
        assert bmain.get_bank_public_key_b64() == expected_pub_b64
        # Clean up env var and restore file-based seed
        del os.environ["BANK_MASTER_SEED"]
        restored_key = bmain.load_or_generate_bank_key(TEST_KEY_SEED_PATH)
        assert bmain.get_bank_public_key_b64() != expected_pub_b64
        print("[PASS] 16. BANK_MASTER_SEED env var loaded, verified and restored fallback successfully.")

        # 17. PostgresCursorWrapper '?' to '%s' conversion verification
        class MockRawCursor:
            def __init__(self):
                self.last_query = None
                self.last_params = None
                self.rowcount = 1
            def execute(self, q, p=None):
                self.last_query = q
                self.last_params = p

        mock_cur = MockRawCursor()
        wrapper = bmain.PostgresCursorWrapper(mock_cur)
        wrapper.execute("SELECT * FROM accounts WHERE account_id = ? AND online_balance >= ?", ("0911000001", 100.0))
        assert mock_cur.last_query == "SELECT * FROM accounts WHERE account_id = %s AND online_balance >= %s"
        assert mock_cur.last_params == ("0911000001", 100.0)
        print("[PASS] 17. PostgresCursorWrapper correctly converted '?' placeholders to '%s'.")

        # 18. PostgresConnectionWrapper transaction & connection closing verification
        class MockRawConn:
            def __init__(self):
                self.committed = False
                self.rolled_back = False
                self.closed = False
            def cursor(self, cursor_factory=None):
                return MockRawCursor()
            def commit(self):
                self.committed = True
            def rollback(self):
                self.rolled_back = True
            def close(self):
                self.closed = True

        mock_conn = MockRawConn()
        with bmain.PostgresConnectionWrapper(mock_conn) as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1")
        assert mock_conn.committed is True
        assert mock_conn.closed is True

        mock_conn_err = MockRawConn()
        try:
            with bmain.PostgresConnectionWrapper(mock_conn_err) as conn:
                raise ValueError("simulated db error")
        except ValueError:
            pass
        assert mock_conn_err.rolled_back is True
        assert mock_conn_err.closed is True
        print("[PASS] 18. PostgresConnectionWrapper commit, rollback, and close verified.")

        print("==================================================================")
        print("ALL 18 BACKEND INTEGRATION TESTS PASSED SUCCESSFULLY!")
        print("==================================================================")

    finally:
        server_thread.stop()
        # Clean up temporary test files
        shutil.rmtree(TEST_DIR, ignore_errors=True)


if __name__ == "__main__":
    test_suite()
