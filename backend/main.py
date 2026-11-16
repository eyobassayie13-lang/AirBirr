import base64
import json
import os
from pathlib import Path
import sqlite3
import struct
import time
from typing import Any, Dict, List, Optional, Tuple, Union
import uuid

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
from fastapi import Body, FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    psycopg2 = None

# ==============================================================================
# 1. CONFIGURATION & FILE PATHS
# ==============================================================================

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def _load_env_file() -> None:
    """Load key-value pairs from root or backend .env into os.environ if not already set."""
    candidates = [
        Path(BASE_DIR).parent / ".env",
        Path(BASE_DIR).parent / ".env.local",
        Path(BASE_DIR) / ".env",
        Path(BASE_DIR) / ".env.local",
    ]
    for env_path in candidates:
        if env_path.is_file():
            try:
                for line in env_path.read_text(encoding="utf-8").splitlines():
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip("'\"")
                        if k and k not in os.environ:
                            os.environ[k] = v
            except Exception:
                pass


_load_env_file()


def _resolve_config_path(env_var: str, default_filename: str) -> str:
    val = os.environ.get(env_var)
    if not val:
        return os.path.join(BASE_DIR, default_filename)
    p = Path(val)
    if p.is_absolute():
        return str(p)
    repo_root = Path(BASE_DIR).parent
    if (repo_root / p).exists() or (repo_root / p.parent).exists():
        return str((repo_root / p).resolve())
    return str((Path(BASE_DIR) / p).resolve())


DB_PATH = _resolve_config_path("OFFPAY_DB_PATH", "master_bank.db")
KEY_SEED_PATH = _resolve_config_path("OFFPAY_KEY_SEED_PATH", "bank_master_key.seed")

# Global holder for bank master keypair
bank_private_key: Optional[ed25519.Ed25519PrivateKey] = None
bank_public_key_raw: Optional[bytes] = None
bank_public_key_b64_str: Optional[str] = None


# ==============================================================================
# 2. MASTER BANK KEYPAIR (Ed25519)
# ==============================================================================


def load_or_generate_bank_key(
    seed_path: Union[Path, str, None] = None,
) -> ed25519.Ed25519PrivateKey:
    """Loads 32-byte Ed25519 seed from BANK_MASTER_SEED env var, local seed file, or generates a new one."""
    global bank_private_key, bank_public_key_b64_str

    # 1. Read BANK_MASTER_SEED from os.environ (Base64 string of 32 bytes)
    env_seed = os.environ.get("BANK_MASTER_SEED")
    if env_seed:
        text = env_seed.strip()
        seed_bytes: Optional[bytes] = None
        try:
            b64 = base64.b64decode(text)
            if len(b64) == 32:
                seed_bytes = b64
        except Exception:
            pass
        if seed_bytes is None and len(text) == 64:
            try:
                seed_bytes = bytes.fromhex(text)
            except Exception:
                pass
        if seed_bytes and len(seed_bytes) == 32:
            bank_private_key = ed25519.Ed25519PrivateKey.from_private_bytes(seed_bytes)
            bank_public_key_b64_str = None
            return bank_private_key

    # 2. Local fallback: read/write bank_master_key.seed on disk
    path = Path(seed_path or KEY_SEED_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists():
        raw_content = path.read_bytes()
        seed_bytes = None

        if len(raw_content) == 32:
            seed_bytes = raw_content
        else:
            text = raw_content.decode("utf-8", errors="ignore").strip()
            # Try Base64
            try:
                b64 = base64.b64decode(text)
                if len(b64) == 32:
                    seed_bytes = b64
            except Exception:
                pass

            # Try Hex
            if seed_bytes is None and len(text) == 64:
                try:
                    seed_bytes = bytes.fromhex(text)
                except Exception:
                    pass

        if seed_bytes and len(seed_bytes) == 32:
            bank_private_key = ed25519.Ed25519PrivateKey.from_private_bytes(seed_bytes)
            bank_public_key_b64_str = None
            return bank_private_key

    # Generate fresh Ed25519 keypair
    private_key = ed25519.Ed25519PrivateKey.generate()
    seed_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    # Persist as Base64 string for portability & inspection
    path.write_text(base64.b64encode(seed_bytes).decode("utf-8"), encoding="utf-8")
    bank_private_key = private_key
    bank_public_key_b64_str = None
    return private_key


def get_bank_public_key_b64() -> str:
    """Returns the Base64-encoded 32-byte public key of the central bank authority."""
    global bank_public_key_b64_str
    if bank_public_key_b64_str:
        return bank_public_key_b64_str

    key = get_bank_private_key()
    pub_bytes = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    bank_public_key_b64_str = base64.b64encode(pub_bytes).decode("utf-8")
    return bank_public_key_b64_str


def get_bank_private_key() -> ed25519.Ed25519PrivateKey:
    global bank_private_key
    if bank_private_key is None:
        bank_private_key = load_or_generate_bank_key(KEY_SEED_PATH)
    return bank_private_key


# ==============================================================================
# 3. DATABASE INITIALIZATION & CONNECTION (PostgreSQL & SQLite)
# ==============================================================================


class PostgresCursorWrapper:
    """Wraps psycopg2 cursor to convert '?' SQL placeholders to '%s'."""

    def __init__(self, cursor: Any):
        self._cursor = cursor

    def execute(self, query: str, params: Any = None):
        converted_query = query.replace("?", "%s")
        if params is not None:
            return self._cursor.execute(converted_query, params)
        return self._cursor.execute(converted_query)

    def fetchone(self):
        return self._cursor.fetchone()

    def fetchall(self):
        return self._cursor.fetchall()

    @property
    def rowcount(self) -> int:
        return self._cursor.rowcount

    def __getattr__(self, name: str) -> Any:
        return getattr(self._cursor, name)


class PostgresConnectionWrapper:
    """Wraps psycopg2 connection to provide DictCursor and handle commit/close context."""

    def __init__(self, conn: Any):
        self._conn = conn

    def cursor(self):
        kwargs = {}
        if psycopg2 is not None and hasattr(psycopg2, "extras"):
            kwargs["cursor_factory"] = psycopg2.extras.DictCursor
        return PostgresCursorWrapper(self._conn.cursor(**kwargs))

    def execute(self, query: str, params: Any = None):
        cur = self.cursor()
        return cur.execute(query, params)

    def commit(self):
        return self._conn.commit()

    def rollback(self):
        return self._conn.rollback()

    def close(self):
        return self._conn.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            if exc_type is not None:
                self._conn.rollback()
            else:
                self._conn.commit()
        finally:
            self._conn.close()


def get_db_connection(db_path: Union[Path, str, None] = None):
    """Opens a PostgreSQL connection via psycopg2 if DATABASE_URL is set; otherwise falls back to SQLite."""
    database_url = os.environ.get("DATABASE_URL")
    if database_url and psycopg2 is not None and db_path is None:
        raw_conn = psycopg2.connect(database_url)
        return PostgresConnectionWrapper(raw_conn)

    path = Path(db_path or DB_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


def init_db(db_path: Union[Path, str, None] = None) -> None:
    """Initializes the database tables (PostgreSQL or SQLite) according to OffPay specification."""
    with get_db_connection(db_path) as conn:
        cursor = conn.cursor()

        # 1. Accounts Table (Customers & Merchants)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS accounts (
                account_id TEXT PRIMARY KEY,
                owner_name TEXT NOT NULL,
                public_key TEXT NOT NULL,
                online_balance DOUBLE PRECISION DEFAULT 1000.0,
                is_merchant INTEGER DEFAULT 0
            );
            """
        )

        # 2. Leases Table (Offline Spending Allowance)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS leases (
                lease_id TEXT PRIMARY KEY,
                payer_pubkey TEXT NOT NULL,
                amount_leased DOUBLE PRECISION NOT NULL,
                expires_at BIGINT NOT NULL,
                is_settled INTEGER DEFAULT 0
            );
            """
        )

        # 3. Cleared Vouchers Table (Append-Only Central Settlement Ledger)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS cleared_vouchers (
                voucher_id TEXT PRIMARY KEY,
                payer_pubkey TEXT NOT NULL,
                payee_id TEXT NOT NULL,
                amount DOUBLE PRECISION NOT NULL,
                nonce BIGINT NOT NULL,
                timestamp BIGINT NOT NULL,
                cleared_at BIGINT NOT NULL,
                UNIQUE(payer_pubkey, nonce)
            );
            """
        )

        # SQLite-specific migration check for legacy SQLite databases
        if not isinstance(conn, PostgresConnectionWrapper):
            cursor.execute(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='cleared_vouchers'"
            )
            table_row = cursor.fetchone()
            if table_row and "UNIQUE(payer_pubkey, nonce)" not in table_row[0].replace(" ", ""):
                cursor.execute(
                    """
                    CREATE TABLE cleared_vouchers_migrated (
                        voucher_id TEXT PRIMARY KEY,
                        payer_pubkey TEXT NOT NULL,
                        payee_id TEXT NOT NULL,
                        amount REAL NOT NULL,
                        nonce INTEGER NOT NULL,
                        timestamp INTEGER NOT NULL,
                        cleared_at INTEGER NOT NULL,
                        UNIQUE(payer_pubkey, nonce)
                    );
                    """
                )
                cursor.execute(
                    """
                    INSERT OR IGNORE INTO cleared_vouchers_migrated 
                    SELECT voucher_id, payer_pubkey, payee_id, amount, nonce, timestamp, cleared_at 
                    FROM cleared_vouchers;
                    """
                )
                cursor.execute("DROP TABLE cleared_vouchers;")
                cursor.execute("ALTER TABLE cleared_vouchers_migrated RENAME TO cleared_vouchers;")

        # Useful indices
        cursor.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_cleared_payer_nonce ON cleared_vouchers(payer_pubkey, nonce);"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_cleared_payee ON cleared_vouchers(payee_id);"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_cleared_payer ON cleared_vouchers(payer_pubkey);"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_leases_payer ON leases(payer_pubkey);"
        )
        conn.commit()


# ==============================================================================
# 4. CRYPTOGRAPHIC HELPERS (Ed25519 & CANONICAL SERIALIZATION)
# ==============================================================================


def canonical_json(obj: Any) -> str:
    """Produces canonical JSON with alphabetically sorted map keys matching Dart CryptoService.canonicalJson."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def sign_bank_message(message_bytes: bytes) -> str:
    """Signs arbitrary bytes using the Bank Master Ed25519 Key and returns Base64 signature."""
    priv = get_bank_private_key()
    sig = priv.sign(message_bytes)
    return base64.b64encode(sig).decode("utf-8")


def verify_ed25519_signature(
    public_key_b64: str,
    message_bytes: bytes,
    signature_b64: str,
) -> bool:
    """Mathematically verifies an Ed25519 signature."""
    try:
        pub_raw = base64.b64decode(public_key_b64.strip())
        sig_raw = base64.b64decode(signature_b64.strip())

        if len(pub_raw) != 32 or len(sig_raw) != 64:
            return False

        pub_key = ed25519.Ed25519PublicKey.from_public_bytes(pub_raw)
        pub_key.verify(sig_raw, message_bytes)
        return True
    except (InvalidSignature, ValueError, Exception):
        return False


def verify_voucher_cryptography(
    voucher_data: Dict[str, Any],
) -> Tuple[bool, str]:
    """Verifies an incoming voucher's authenticity mathematically using Ed25519.

    Supports both:
    1. Canonical JSON signing (as produced by Dart CryptoService.signPayload)
    2. Binary-packed 60-byte payload + 64-byte signature (OffPay Rule 4, 124 bytes total)
    """
    signature_b64 = voucher_data.get("signature")
    payer_pubkey = voucher_data.get("payer_pubkey") or voucher_data.get("payer")
    raw_bytes_b64 = voucher_data.get("raw_bytes")

    if not payer_pubkey:
        return False, "Missing payer public key"

    # --- Mode A: 124-byte packed binary format ---
    if raw_bytes_b64:
        try:
            packed_bytes = base64.b64decode(raw_bytes_b64)
            if len(packed_bytes) == 124:
                payload_bytes = packed_bytes[:60]
                sig_bytes = packed_bytes[60:124]
                payer_pub = ed25519.Ed25519PublicKey.from_public_bytes(
                    base64.b64decode(payer_pubkey)
                )
                payer_pub.verify(sig_bytes, payload_bytes)
                return True, "Valid packed binary voucher"
        except Exception:
            pass

    if not signature_b64:
        return False, "Missing cryptographic signature"

    # --- Mode B: Canonical JSON payload signing ---
    # Construct candidate signing dicts (excluding signature and raw_bytes)
    candidate_dicts = []

    # 1. Copy of the exact payload without signature/raw_bytes/cleared_at
    base_dict = {
        k: v
        for k, v in voucher_data.items()
        if k not in ("signature", "raw_bytes", "cleared_at", "is_synced")
        and v is not None
    }
    candidate_dicts.append(base_dict)

    # 2. Standardized OffPay wire payload format: {voucher_id, payer, payee, amount, nonce, timestamp}
    voucher_id = voucher_data.get("voucher_id") or voucher_data.get("id")
    payee = voucher_data.get("payee") or voucher_data.get("payee_id") or ""
    nonce = voucher_data.get("nonce")
    timestamp = voucher_data.get("timestamp")
    amount = voucher_data.get("amount")

    if amount is None and voucher_data.get("amount_cents") is not None:
        amount = voucher_data["amount_cents"] / 100.0

    if voucher_id and nonce is not None and timestamp is not None and amount is not None:
        # Standard float representation
        candidate_dicts.append({
            "voucher_id": str(voucher_id),
            "payer": str(payer_pubkey),
            "payee": str(payee),
            "amount": float(amount),
            "nonce": int(nonce),
            "timestamp": int(timestamp),
        })
        # If integer amount, test integer representation
        if float(amount).is_integer():
            candidate_dicts.append({
                "voucher_id": str(voucher_id),
                "payer": str(payer_pubkey),
                "payee": str(payee),
                "amount": int(amount),
                "nonce": int(nonce),
                "timestamp": int(timestamp),
            })
        # Alternative field names: payer_pubkey / payee_id
        candidate_dicts.append({
            "voucher_id": str(voucher_id),
            "payer_pubkey": str(payer_pubkey),
            "payee_id": str(payee),
            "amount": float(amount),
            "nonce": int(nonce),
            "timestamp": int(timestamp),
        })

    # Try verifying candidates against canonical JSON
    for candidate in candidate_dicts:
        candidate_bytes = canonical_json(candidate).encode("utf-8")
        if verify_ed25519_signature(payer_pubkey, candidate_bytes, signature_b64):
            return True, "Valid canonical JSON signature"

    # --- Mode C: Binary 60-byte payload reconstructed from fields ---
    try:
        payer_raw = base64.b64decode(payer_pubkey)
        if len(payer_raw) == 32 and nonce is not None and timestamp is not None and amount is not None:
            amount_cents = int(round(float(amount) * 100))
            payee_bytes = str(payee).encode("utf-8")[:16].ljust(16, b"\x00")
            binary_payload = struct.pack(
                ">32s16sIII",
                payer_raw,
                payee_bytes,
                amount_cents,
                int(nonce),
                int(timestamp),
            )
            if verify_ed25519_signature(payer_pubkey, binary_payload, signature_b64):
                return True, "Valid reconstructed binary payload signature"
    except Exception:
        pass

    return False, "Ed25519 mathematical verification failed"


# ==============================================================================
# 5. PYDANTIC REQUEST / RESPONSE SCHEMAS
# ==============================================================================


class BankPublicKeyResponse(BaseModel):
    public_key: str = Field(..., description="Base64 encoded 32-byte Ed25519 public key")
    key_type: str = "Ed25519"
    issuer: str = "AirBirr Central Clearinghouse"


class MerchantCertificate(BaseModel):
    owner_name: str
    public_key: str
    signature: str = Field(..., description="Sign_Bank(owner_name + public_key)")
    issuer_public_key: str
    issued_at: int


class RegisterRequest(BaseModel):
    account_id: str = Field(..., description="Unique account identifier (phone number or merchant ID)")
    owner_name: Optional[str] = Field(default=None, description="Display or business owner name")
    public_key: str = Field(..., description="User's Base64 Ed25519 public key")
    is_merchant: Optional[bool] = Field(default=False, description="Whether registering as a merchant terminal")


class RegisterResponse(BaseModel):
    account_id: str
    owner_name: str
    public_key: str
    online_balance: float
    is_merchant: bool
    certificate: Optional[MerchantCertificate] = None


class LeaseIssueRequest(BaseModel):
    account_id: str
    amount_to_lease: float = Field(..., gt=0, description="Amount in ETB to lease for offline spending")
    duration_days: int = Field(default=7, gt=0, description="Lease duration in days")


class LeaseCertificate(BaseModel):
    lease_id: str
    payer_pubkey: str
    max_allowance: float
    expires_at: int
    signature: str = Field(..., description="Bank Master Key signature over canonical lease payload")
    issuer_public_key: str


class LeaseIssueResponse(BaseModel):
    lease_id: str
    account_id: str
    amount_leased: float
    remaining_online_balance: float
    certificate: LeaseCertificate
    lease_certificate: LeaseCertificate  # Provided for convenience/alias


class VoucherModel(BaseModel):
    voucher_id: Optional[str] = None
    payer: Optional[str] = None
    payer_pubkey: Optional[str] = None
    payee: Optional[str] = None
    payee_id: Optional[str] = None
    amount: Optional[float] = None
    amount_cents: Optional[int] = None
    nonce: Optional[int] = 0
    timestamp: Optional[int] = 0
    signature: Optional[str] = ""
    raw_bytes: Optional[str] = None

    @property
    def clean_payer(self) -> str:
        return self.payer_pubkey or self.payer or ""

    @property
    def clean_payee(self) -> str:
        return self.payee_id or self.payee or ""

    @property
    def clean_amount(self) -> float:
        if self.amount is not None:
            return round(float(self.amount), 2)
        if self.amount_cents is not None:
            return round(float(self.amount_cents) / 100.0, 2)
        return 0.0


VoucherSyncItem = VoucherModel


class BatchSyncRequest(BaseModel):
    vouchers: List[VoucherModel]


class RejectedVoucherDetail(BaseModel):
    voucher_id: Optional[str] = None
    reason: str


class BatchSyncResponse(BaseModel):
    settled_voucher_ids: List[str]
    settled_vouchers: List[str]  # Alias
    newly_cleared_count: int
    already_synced_count: int
    rejected_count: int
    rejected_vouchers: List[RejectedVoucherDetail] = []


class ClearedVoucherRecord(BaseModel):
    voucher_id: str
    payer_pubkey: str
    payee_id: str
    amount: float
    nonce: int
    timestamp: int
    cleared_at: int


class LeaseRecord(BaseModel):
    lease_id: str
    payer_pubkey: str
    amount_leased: float
    expires_at: int
    is_settled: int


class AccountDetailResponse(BaseModel):
    account_id: str
    owner_name: str
    public_key: str
    online_balance: float
    is_merchant: bool
    received_vouchers: List[ClearedVoucherRecord] = []
    sent_vouchers: List[ClearedVoucherRecord] = []
    leases: List[LeaseRecord] = []


# ==============================================================================
# 6. FASTAPI APPLICATION SETUP
# ==============================================================================

app = FastAPI(
    title="AirBirr (OffPay) Central Clearinghouse & Identity Authority",
    version="1.0.0",
    description="Central Bank Master Authority, Offline Lease Issuance, and Voucher Clearinghouse",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def startup_event():
    """Initializes the database schema and ensures Bank Master keypair is loaded on startup."""
    init_db()
    load_or_generate_bank_key()
    get_bank_public_key_b64()


@app.get("/", tags=["Health"])
@app.get("/api/v1/health", tags=["Health"])
def health_check():
    is_pg = bool(os.environ.get("DATABASE_URL") and psycopg2 is not None)
    db_name = "postgresql" if is_pg else os.path.basename(str(DB_PATH))
    return {
        "status": "healthy",
        "service": "AirBirr Central Clearinghouse",
        "bank_public_key": get_bank_public_key_b64(),
        "database": db_name,
    }


# ==============================================================================
# 7. ENDPOINT IMPLEMENTATIONS
# ==============================================================================


@app.get(
    "/api/v1/bank/public-key",
    response_model=BankPublicKeyResponse,
    summary="Get Bank Master Public Key",
    tags=["Authority"],
)
def get_bank_public_key():
    """Returns the Central Bank's Base64 Ed25519 Public Key.

    This key serves as the cryptographic root of trust for offline mobile clients.
    """
    return BankPublicKeyResponse(
        public_key=get_bank_public_key_b64(),
        key_type="Ed25519",
        issuer="AirBirr Central Clearinghouse",
    )


@app.post(
    "/api/v1/auth/register",
    status_code=status.HTTP_200_OK,
    summary="Register Account (Customer or Merchant)",
    tags=["Accounts"],
)
def register_account(req: RegisterRequest):
    """Creates a new customer or merchant account with an initial 1000.0 ETB online balance.

    If is_merchant is true, issues a Bank-Signed Identity Certificate:
    Sign_Bank(owner_name + public_key)
    """
    account_id = req.account_id.strip()
    owner_name = (req.owner_name or req.account_id).strip()
    public_key = req.public_key.strip()

    if not account_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="account_id cannot be empty")
    if not owner_name:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="owner_name cannot be empty")

    # Validate Base64 public key (32 bytes)
    try:
        decoded_pub = base64.b64decode(public_key)
        if len(decoded_pub) != 32:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"public_key must be exactly 32 bytes (got {len(decoded_pub)})",
            )
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="public_key must be valid 32-byte Base64 Ed25519 key",
        )

    with get_db_connection() as conn:
        cursor = conn.cursor()

        # Check existing account
        cursor.execute(
            "SELECT account_id, owner_name, public_key, online_balance, is_merchant FROM accounts WHERE account_id = ?",
            (account_id,),
        )
        acc = cursor.fetchone()
        if acc:
            return JSONResponse(
                status_code=status.HTTP_200_OK,
                content={
                    "status": "already_registered",
                    "account_id": req.account_id,
                    "online_balance": float(acc["online_balance"]),
                },
            )

        initial_balance = 1000000.0  # 1 Million ETB initial test balance
        is_merchant_int = 1 if req.is_merchant else 0

        cursor.execute(
            """
            INSERT INTO accounts (account_id, owner_name, public_key, online_balance, is_merchant)
            VALUES (?, ?, ?, ?, ?)
            """,
            (account_id, owner_name, public_key, initial_balance, is_merchant_int),
        )
        conn.commit()

    certificate: Optional[MerchantCertificate] = None
    if req.is_merchant:
        # Sign_Bank(owner_name + public_key)
        cert_message = f"{owner_name}{public_key}".encode("utf-8")
        signature = sign_bank_message(cert_message)
        certificate = MerchantCertificate(
            owner_name=owner_name,
            public_key=public_key,
            signature=signature,
            issuer_public_key=get_bank_public_key_b64(),
            issued_at=int(time.time()),
        )

    return RegisterResponse(
        account_id=account_id,
        owner_name=owner_name,
        public_key=public_key,
        online_balance=initial_balance,
        is_merchant=bool(req.is_merchant),
        certificate=certificate,
    )


@app.post(
    "/api/v1/lease/issue",
    response_model=LeaseIssueResponse,
    summary="Issue Offline Lease Certificate",
    tags=["Leases"],
)
def issue_lease(req: LeaseIssueRequest):
    """Verifies account balance, atomically deducts amount_to_lease from online_balance,

    and generates a signed LeaseCertificate:
    Payload: {lease_id, payer_pubkey, max_allowance, expires_at}
    Signed by the Bank's Master Private Key.
    """
    account_id = req.account_id.strip()
    amount_to_lease = round(float(req.amount_to_lease), 2)
    duration_days = req.duration_days

    if amount_to_lease <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Lease amount must be greater than zero",
        )
    if duration_days <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Lease duration must be at least 1 day",
        )

    lease_id = f"lease_{uuid.uuid4().hex[:16]}"
    now = int(time.time())
    expires_at = now + (duration_days * 86400)

    with get_db_connection() as conn:
        cursor = conn.cursor()

        # Atomic transaction: Check and deduct balance
        cursor.execute(
            "SELECT account_id, owner_name, public_key, online_balance FROM accounts WHERE account_id = ?",
            (account_id,),
        )
        account = cursor.fetchone()
        if not account:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Account '{account_id}' not found",
            )

        current_balance = float(account["online_balance"])
        payer_pubkey = account["public_key"]

        if current_balance < amount_to_lease:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Insufficient online balance. Current: {current_balance:.2f} ETB, Requested: {amount_to_lease:.2f} ETB",
            )

        new_balance = round(current_balance - amount_to_lease, 2)

        # Atomic update
        cursor.execute(
            """
            UPDATE accounts
            SET online_balance = online_balance - ?
            WHERE account_id = ? AND online_balance >= ?
            """,
            (amount_to_lease, account_id, amount_to_lease),
        )
        if cursor.rowcount == 0:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Transaction conflict or insufficient funds during deduction",
            )

        # Record lease
        cursor.execute(
            """
            INSERT INTO leases (lease_id, payer_pubkey, amount_leased, expires_at, is_settled)
            VALUES (?, ?, ?, ?, 0)
            """,
            (lease_id, payer_pubkey, amount_to_lease, expires_at),
        )
        conn.commit()

    # Generate signed LeaseCertificate:
    # Payload: {lease_id, payer_pubkey, max_allowance, expires_at}
    cert_payload = {
        "expires_at": expires_at,
        "lease_id": lease_id,
        "max_allowance": amount_to_lease,
        "payer_pubkey": payer_pubkey,
    }
    cert_bytes = canonical_json(cert_payload).encode("utf-8")
    signature = sign_bank_message(cert_bytes)

    certificate = LeaseCertificate(
        lease_id=lease_id,
        payer_pubkey=payer_pubkey,
        max_allowance=amount_to_lease,
        expires_at=expires_at,
        signature=signature,
        issuer_public_key=get_bank_public_key_b64(),
    )

    return LeaseIssueResponse(
        lease_id=lease_id,
        account_id=account_id,
        amount_leased=amount_to_lease,
        remaining_online_balance=new_balance,
        certificate=certificate,
        lease_certificate=certificate,
    )


@app.post(
    "/api/v1/settlement/batch-sync",
    response_model=BatchSyncResponse,
    summary="Batch Settle Offline Vouchers",
    tags=["Settlement"],
)
def batch_sync_vouchers(
    body: Union[BatchSyncRequest, List[VoucherModel]] = Body(...),
):
    """Settles a batch of offline vouchers submitted by merchants, customers, or data mules.

    1. Idempotency Check: Already cleared vouchers are marked as settled and skipped from re-crediting.
    2. Mathematical Ed25519 Verification: Verifies payer signature against clean_payer.
    3. Atomic Commit: Inserts into cleared_vouchers, credits clean_payee, and debits clean_payer (if account exists).
    """
    vouchers: List[VoucherModel] = (
        body if isinstance(body, list) else body.vouchers
    )

    settled_ids: List[str] = []
    rejected_list: List[RejectedVoucherDetail] = []
    newly_cleared_count = 0
    already_synced_count = 0

    with get_db_connection() as conn:
        cursor = conn.cursor()

        for item in vouchers:
            v_dict = item.model_dump()
            payer_pubkey = item.clean_payer
            payee_id = item.clean_payee
            amount = item.clean_amount
            nonce = item.nonce if item.nonce is not None else 0
            timestamp = item.timestamp if item.timestamp is not None else int(time.time())

            # Determine voucher_id
            voucher_id = item.voucher_id
            if not voucher_id:
                if payer_pubkey and nonce is not None:
                    voucher_id = f"{payer_pubkey}_{nonce}"
                else:
                    voucher_id = f"voucher_{uuid.uuid4().hex[:12]}"
            v_dict["voucher_id"] = voucher_id
            v_dict["payer_pubkey"] = payer_pubkey
            v_dict["payee_id"] = payee_id
            v_dict["amount"] = amount

            # 1. Nonce Integrity & Idempotency Check:
            # Query if (payer_pubkey, nonce) already exists in cleared_vouchers
            cursor.execute(
                "SELECT voucher_id FROM cleared_vouchers WHERE payer_pubkey = ? AND nonce = ?",
                (payer_pubkey, int(nonce)),
            )
            existing_nonce_row = cursor.fetchone()
            if existing_nonce_row:
                existing_voucher_id = existing_nonce_row["voucher_id"]
                if existing_voucher_id == voucher_id:
                    # The exact same voucher_id already exists: mark as already settled (idempotent duplicate), skip re-crediting
                    already_synced_count += 1
                    settled_ids.append(voucher_id)
                    continue
                else:
                    # A DIFFERENT voucher_id tries to use an ALREADY-USED nonce from the same payer_pubkey
                    rejected_list.append(
                        RejectedVoucherDetail(
                            voucher_id=voucher_id,
                            reason="Nonce collision / Replay attack detected",
                        )
                    )
                    continue

            # Check if voucher_id already in cleared_vouchers
            cursor.execute(
                "SELECT voucher_id FROM cleared_vouchers WHERE voucher_id = ?",
                (voucher_id,),
            )
            if cursor.fetchone():
                already_synced_count += 1
                settled_ids.append(voucher_id)
                continue

            # 2. Verify Ed25519 signature
            is_valid, reason = verify_voucher_cryptography(v_dict)
            if not is_valid:
                rejected_list.append(
                    RejectedVoucherDetail(voucher_id=voucher_id, reason=reason)
                )
                continue

            # 3. Valid voucher: Insert into cleared_vouchers
            cleared_at = int(time.time())
            cursor.execute(
                """
                INSERT INTO cleared_vouchers (voucher_id, payer_pubkey, payee_id, amount, nonce, timestamp, cleared_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    voucher_id,
                    payer_pubkey,
                    payee_id,
                    amount,
                    int(nonce),
                    int(timestamp),
                    cleared_at,
                ),
            )

            # Credit clean_payee online_balance (matches by account_id or owner_name)
            if payee_id:
                cursor.execute(
                    """
                    UPDATE accounts
                    SET online_balance = online_balance + ?
                    WHERE account_id = ? OR owner_name = ?
                    """,
                    (amount, payee_id, payee_id),
                )

            # Debit clean_payer online_balance (if account exists)
            if payer_pubkey:
                cursor.execute(
                    """
                    UPDATE accounts
                    SET online_balance = online_balance - ?
                    WHERE public_key = ? OR account_id = ? OR owner_name = ?
                    """,
                    (amount, payer_pubkey, payer_pubkey, payer_pubkey),
                )

            newly_cleared_count += 1
            settled_ids.append(voucher_id)

        conn.commit()

    return BatchSyncResponse(
        settled_voucher_ids=settled_ids,
        settled_vouchers=settled_ids,
        newly_cleared_count=newly_cleared_count,
        already_synced_count=already_synced_count,
        rejected_count=len(rejected_list),
        rejected_vouchers=rejected_list,
    )


@app.get(
    "/api/v1/accounts",
    summary="List All Registered Accounts",
    tags=["Accounts"],
)
def list_accounts():
    """Returns a list of all registered accounts in the Central Bank ledger."""
    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT account_id, owner_name, public_key, online_balance, is_merchant
            FROM accounts
            ORDER BY account_id ASC
            """
        )
        rows = cursor.fetchall()
        return [
            {
                "account_id": r["account_id"],
                "owner_name": r["owner_name"],
                "public_key": r["public_key"],
                "online_balance": float(r["online_balance"]),
                "is_merchant": bool(r["is_merchant"]),
            }
            for r in rows
        ]


@app.get(
    "/api/v1/accounts/{account_id}",
    response_model=AccountDetailResponse,
    summary="Get Account Details & Full Transaction History",
    tags=["Accounts"],
)
def get_account_detail(account_id: str):
    """Returns current account details, online balance, received vouchers,

    sent vouchers, and active leases.
    """
    account_id = account_id.strip()

    with get_db_connection() as conn:
        cursor = conn.cursor()

        cursor.execute(
            "SELECT account_id, owner_name, public_key, online_balance, is_merchant FROM accounts WHERE account_id = ?",
            (account_id,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Account '{account_id}' not found",
            )

        owner_name = row["owner_name"]
        pubkey = row["public_key"]

        # Received vouchers: where this account is payee (by owner_name or account_id)
        cursor.execute(
            """
            SELECT voucher_id, payer_pubkey, payee_id, amount, nonce, timestamp, cleared_at
            FROM cleared_vouchers
            WHERE payee_id = ? OR payee_id = ?
            ORDER BY cleared_at DESC
            """,
            (owner_name, account_id),
        )
        received_rows = cursor.fetchall()
        received_vouchers = [
            ClearedVoucherRecord(
                voucher_id=r["voucher_id"],
                payer_pubkey=r["payer_pubkey"],
                payee_id=r["payee_id"],
                amount=float(r["amount"]),
                nonce=int(r["nonce"]),
                timestamp=int(r["timestamp"]),
                cleared_at=int(r["cleared_at"]),
            )
            for r in received_rows
        ]

        # Sent vouchers: where this account was the payer (matching public key, excluding self-transfers)
        cursor.execute(
            """
            SELECT voucher_id, payer_pubkey, payee_id, amount, nonce, timestamp, cleared_at
            FROM cleared_vouchers
            WHERE payer_pubkey = ? AND payee_id != ? AND payee_id != ?
            ORDER BY cleared_at DESC
            """,
            (pubkey, owner_name, account_id),
        )
        sent_rows = cursor.fetchall()
        sent_vouchers = [
            ClearedVoucherRecord(
                voucher_id=r["voucher_id"],
                payer_pubkey=r["payer_pubkey"],
                payee_id=r["payee_id"],
                amount=float(r["amount"]),
                nonce=int(r["nonce"]),
                timestamp=int(r["timestamp"]),
                cleared_at=int(r["cleared_at"]),
            )
            for r in sent_rows
        ]

        # Leases: issued to this account's public key
        cursor.execute(
            """
            SELECT lease_id, payer_pubkey, amount_leased, expires_at, is_settled
            FROM leases
            WHERE payer_pubkey = ?
            ORDER BY expires_at DESC
            """,
            (pubkey,),
        )
        lease_rows = cursor.fetchall()
        leases = [
            LeaseRecord(
                lease_id=r["lease_id"],
                payer_pubkey=r["payer_pubkey"],
                amount_leased=float(r["amount_leased"]),
                expires_at=int(r["expires_at"]),
                is_settled=int(r["is_settled"]),
            )
            for r in lease_rows
        ]

    return AccountDetailResponse(
        account_id=row["account_id"],
        owner_name=row["owner_name"],
        public_key=row["public_key"],
        online_balance=float(row["online_balance"]),
        is_merchant=bool(row["is_merchant"]),
        received_vouchers=received_vouchers,
        sent_vouchers=sent_vouchers,
        leases=leases,
    )


# ==============================================================================
# 8. DIRECT RUN (UVICORN)
# ==============================================================================

if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8000"))
    uvicorn.run("main:app", host=host, port=port, reload=True)
