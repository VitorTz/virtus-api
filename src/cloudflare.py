from botocore.config import Config
from typing import Optional, List
from asyncio import Lock
from dotenv import load_dotenv
import aioboto3
import os
import io

load_dotenv()


class CloudflareR2Bucket:
    _instance = None
    _lock = Lock()

    def __init__(
        self,
        account_id: str,
        access_key_id: str,
        secret_access_key: str,
        bucket_name: str,
        region: str = "auto",
    ):
        self.bucket_name = bucket_name
        self.prefix = os.getenv("CLOUDFLARE_PREFIX")
        self.endpoint_url = f"https://{account_id}.r2.cloudflarestorage.com"
        self.session = aioboto3.Session()
        self.config = Config(signature_version="s3v4")
        self.credentials = {
            "aws_access_key_id": access_key_id,
            "aws_secret_access_key": secret_access_key,
        }
        self._initialized = True

    @classmethod
    async def get_instance(
        cls,
        account_id: str = os.getenv("CLOUDFLARE_ACCOUNT_ID"),
        access_key_id: str = os.getenv("CLOUDFLARE_ACCESS_KEY"),
        secret_access_key: str = os.getenv("CLOUDFLARE_SECRET_ACCESS_KEY"),
        bucket_name: str = os.getenv("CLOUDFLARE_BUCKET_NAME"),
        region: str = "auto",
    ):
        if not cls._instance:
            async with cls._lock:
                if not cls._instance:
                    cls._instance = cls(
                        account_id,
                        access_key_id,
                        secret_access_key,
                        bucket_name,
                        region,
                    )
        return cls._instance

    async def _get_client(self):
        return self.session.client(
            "s3",
            endpoint_url=self.endpoint_url,
            region_name="auto",
            config=self.config,
            **self.credentials,
        )

    async def upload_file(self, key: str, file_path: str, content_type: Optional[str] = None):
        async with await self._get_client() as s3:
            extra = {"ContentType": content_type} if content_type else {}
            await s3.upload_file(file_path, self.bucket_name, key, ExtraArgs=extra)

    async def upload_bytes(self, key: str, data: io.BytesIO, content_type: Optional[str] = None) -> str:
        async with await self._get_client() as s3:
            extra = {"ContentType": content_type} if content_type else {}
            await s3.upload_fileobj(data, self.bucket_name, key, ExtraArgs=extra)
            return self.prefix + key

    async def download_file(self, key: str, dest_path: str):
        async with await self._get_client() as s3:
            await s3.download_file(self.bucket_name, key, dest_path)

    async def get_url(self, key: str, expires_in: int = 3600) -> str:
        async with await self._get_client() as s3:
            return await s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": self.bucket_name, "Key": key},
                ExpiresIn=expires_in,
            )

    async def list_files(self, prefix: str = "") -> List[str]:
        async with await self._get_client() as s3:
            resp = await s3.list_objects_v2(Bucket=self.bucket_name, Prefix=prefix)
            return [item["Key"] for item in resp.get("Contents", [])] if "Contents" in resp else []

    async def delete_file(self, key: str):
        async with await self._get_client() as s3:
            await s3.delete_object(Bucket=self.bucket_name, Key=key)

    def extract_key(self, url: str) -> str:
        return url.replace(self.prefix, '').strip()