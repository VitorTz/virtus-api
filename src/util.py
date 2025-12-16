from fastapi import UploadFile
from datetime import datetime, timezone
from fastapi import Request
from typing import Any
from PIL import Image
import io
import uuid
import re


def coalesce(a: Any, b: Any) -> Any:
    if a: return a
    return b


def validate_cpf(v: str) -> str:
    if not v: return v
        
    cpf = re.sub(r'[^0-9]', '', v)
    
    if len(cpf) != 11:
        raise ValueError('CPF deve conter 11 dígitos')
    
    if cpf == cpf[0] * 11:
        raise ValueError('CPF inválido')
        
    return cpf


def remove_non_digits(r: str) -> str:
    return re.sub(r'\D', '', r)


def sanitaze_phone(phone: str) -> str:
    digits = ''
    for x in phone:
        if x.isdigit(): digits += x
    if len(digits) == 10:
        digits = digits[0:2] + '9' + digits[2:]
    return f"({digits[0]}{digits[1]}) {digits[2]} {digits[3:7]}-{digits[7:]}"


def sanitaze_cpf(cpf: str) -> str:
    digits = ''
    for x in cpf:
        if x.isdigit(): digits += x
    return f"{digits[0:3]}.{digits[3:6]}.{digits[6:9]}-{digits[9:]}"


def mask_cpf(cpf: str) -> str:
    if not cpf: return cpf
    digits = ''.join(filter(str.isdigit, cpf))
    if len(digits) != 11: raise ValueError("CPF must contain exactly 11 digits")
    return f"***.{digits[3:6]}.***-**"


def get_client_identifier(request: Request) -> str:
    forwarded_for = request.headers.get("X-Forwarded-For")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()
    
    real_ip = request.headers.get("X-Real-IP")
    if real_ip:
        return real_ip

    return request.client.host


def seconds_until(target: datetime) -> int:
    if target.tzinfo is None:
        target = target.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    diff = (target - now).total_seconds()
    return int(diff) if diff > 0 else 0


def minutes_until(target: datetime) -> int:
    if target.tzinfo is None:
        target = target.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    diff = (target - now).total_seconds() / 60
    return int(diff) if diff > 0 else 0


def minutes_since(ts: datetime) -> int:
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    diff = (now - ts).total_seconds() / 60
    return int(diff) if diff > 0 else 0


def generate_uuid() -> str:
    return str(uuid.uuid4())


async def convert_upload_to_webp(file: UploadFile, quality: int = 80) -> io.BytesIO:
    contents = await file.read()
    image = Image.open(io.BytesIO(contents))

    buffer = io.BytesIO()
    image.save(buffer, format="WEBP", quality=quality, method=6)
    buffer.seek(0)

    return buffer
