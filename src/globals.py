import redis.asyncio as redis
from src.constants import Constants
from dotenv import load_dotenv
import os


load_dotenv()


REDIS_URL = os.getenv("REDIS_URL") if Constants.IS_PRODUCTION else os.getenv("REDIS_URL_DEV")


redis_client = redis.from_url(REDIS_URL, decode_responses=True)


def globals_get_redis_client():
    global redis_client
    return redis_client