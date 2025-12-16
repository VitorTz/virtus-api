from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi import FastAPI, Response, Request, status
from starlette.middleware.gzip import GZipMiddleware
from src.monitor import periodic_update, get_monitor
from fastapi.middleware.cors import CORSMiddleware
from src.cloudflare import CloudflareR2Bucket
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from src.exceptions import DatabaseError
from src.constants import Constants
from src.routes import auth
from src.routes import feedback
from src.routes import currency
from src.routes import cnpj
from src.routes import staff
from src.routes import address
from src.model import log as log_model
from src.db.db import db
from src import middleware
from src import util
from src.globals import globals_get_redis_client
import contextlib
import asyncio
import time


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"[API] [STARTING {Constants.API_NAME}]")    
    
    # [PostgreSql INIT]
    await db.connect()
    
    # [System Monitor]
    task = asyncio.create_task(periodic_update())
    
    # [Cloudflare]
    app.state.r2 = await CloudflareR2Bucket.get_instance()

    print(f"[API] [{Constants.API_NAME} STARTED]")

    yield
    
    # [SystemMonitor]
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await task
    
    # [PostgreSql CLOSE]
    await db.disconnect()
    
    # [Cloudflare CLOSE]
    if hasattr(app.state.r2, "close"):
        await app.state.r2.close()

    print(f"[API] [SHUTTING DOWN {Constants.API_NAME}]")

    
app = FastAPI(    
    title=Constants.API_NAME, 
    description=Constants.API_DESCR,
    version=Constants.API_VERSION,
    lifespan=lifespan
)

app.mount("/static", StaticFiles(directory="static"), name="static")


if Constants.IS_PRODUCTION:
    origins = ["https://vitortz.github.io"]
else:
    origins = ["http://localhost:5173"]


app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
def read_root():
    return {"status": "ok"}


@app.get("/favicon.ico")
async def favicon():
    return FileResponse("static/favicon/favicon.ico")


############################ ROUTES #############################

app.include_router(auth.router, prefix='/api/v1/auth', tags=['auth'])
app.include_router(staff.router, prefix='/api/v1/staff', tags=['staff'])
app.include_router(feedback.router, prefix='/api/v1/feedback', tags=['feedback'])
app.include_router(currency.router, prefix='/api/v1/currency', tags=['currency'])
app.include_router(address.router, prefix='/api/v1/cep', tags=['cep'])
app.include_router(cnpj.router, prefix='/api/v1/cnpj', tags=['cnpj'])


########################## MIDDLEWARES ##########################

app.add_middleware(GZipMiddleware, minimum_size=1000)

@app.middleware("http")
async def http_middleware(request: Request, call_next):
    start_time = time.perf_counter()
    
    # Body size check
    content_length = request.headers.get("content-length")
    if content_length:
        if int(content_length) > Constants.MAX_BODY_SIZE:
            raise HTTPException(
                status_code=413,
                detail=f"Request entity too large. Max allowed: {Constants.MAX_BODY_SIZE} bytes"
            )
    else:
        body = b""
        async for chunk in request.stream():
            body += chunk
            if len(body) > Constants.MAX_BODY_SIZE:
                raise HTTPException(
                    status_code=413,
                    detail=f"Request entity too large. Max allowed: {Constants.MAX_BODY_SIZE} bytes"
                )
        request._body = body
    
    # Rate limit check
    identifier = util.get_client_identifier(request)
    key = f"rate_limit:{identifier}"
    
    pipe = globals_get_redis_client().pipeline()
    pipe.incr(key)
    pipe.expire(key, Constants.WINDOW)
    results = await pipe.execute()
    
    current = results[0]
    ttl = await globals_get_redis_client().ttl(key)
    
    if current > Constants.MAX_REQUESTS:    
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={
                "error": "Too many requests",
                "message": f"Rate limit exceeded. Try again in {ttl} seconds.",
                "retry_after": ttl,
                "limit": Constants.MAX_REQUESTS,
                "window": Constants.WINDOW
            },
            headers={
                "Retry-After": str(ttl),
                "X-RateLimit-Limit": str(Constants.MAX_REQUESTS),
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": str(ttl)
            }
        )
    
    response: Response = await call_next(request)
    
    # Headers
    remaining = max(Constants.MAX_REQUESTS - current, 0)
    response.headers["X-RateLimit-Limit"] = str(Constants.MAX_REQUESTS)
    response.headers["X-RateLimit-Remaining"] = str(remaining)
    response.headers["X-RateLimit-Reset"] = str(ttl)        
    middleware.add_security_headers(request, response)
    response_time_ms = (time.perf_counter() - start_time) * 1000
    response.headers["X-Response-Time"] = f"{response_time_ms:.2f}ms"
    
    # System Monitor
    get_monitor().increment_request(response_time_ms)

    return response


@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    return await log_model.log_and_build_response(
        request=request,
        exc=exc,
        error_level="WARN" if exc.status_code < 500 else "ERROR",
        status_code=exc.status_code,
        detail=exc.detail
    )


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return await log_model.log_and_build_response(
        request=request,
        exc=exc,
        error_level="WARN",
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        detail={
            "message": "Validation error",
            "errors": exc.errors()
        }
    )


@app.exception_handler(DatabaseError)
async def global_exception_handler(request: Request, exc: DatabaseError):
    return await log_model.log_and_build_response(
        request=request,
        exc=exc,
        error_level="ERROR",
        status_code=exc.code if exc.code else status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail=exc.detail
    )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    return await log_model.log_and_build_response(
        request=request,
        exc=exc,
        error_level="FATAL",
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="Internal server error"
    )