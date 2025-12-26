from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi import FastAPI, Response, Request, status
from fastapi_limiter import FastAPILimiter
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
from src.routes import companies
from src.routes import audit
from src.routes import staff
from src.routes import address
from src.routes import ncm
from src.routes import monitor
from src.routes import logs
from src.model import log as log_model
from src.db.db import db
from src.services.redis_client import RedisService
import uvicorn
import contextlib
import asyncio
import time


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"[API] [STARTING {Constants.API_NAME}]")    
    
    # [Redis]
    await RedisService.check_connection()
    
    # [PostgreSql INIT]
    await db.connect()
    
    # [System Monitor]
    task = asyncio.create_task(periodic_update())
    
    # [Cloudflare]
    app.state.r2 = await CloudflareR2Bucket.get_instance()
    
    # [Limiter]
    await FastAPILimiter.init(RedisService.get_client())

    print(f"[API] [{Constants.API_NAME} STARTED]")

    yield
    
    # [Redis]
    await RedisService.close()
    
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
    max_age=3600
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
app.include_router(companies.router, prefix='/api/v1/companies', tags=['companies'])
app.include_router(audit.router, prefix='/api/v1/audit', tags=['audit'])
app.include_router(ncm.router, prefix='/api/v1/ncm', tags=['ncm'])
app.include_router(monitor.router, prefix='/api/v1/admin/monitor', tags=['monitor'])
app.include_router(logs.router, prefix='/api/v1/admin/logs', tags=['logs'])

########################## MIDDLEWARES ##########################

app.add_middleware(GZipMiddleware, minimum_size=1000)


@app.middleware("http")
async def security_middleware(request: Request, call_next):
    start_time = time.perf_counter()
    
    # 1. Body size check (otimizado)
    content_length = request.headers.get("content-length")
    if content_length:
        if int(content_length) > Constants.MAX_BODY_SIZE:
            raise HTTPException(
                status_code=413,
                detail=f"Request too large. Max: {Constants.MAX_BODY_SIZE} bytes"
            )
    else:
        # Streaming check (otimizado)
        chunks = []
        total_size = 0
        async for chunk in request.stream():
            chunks.append(chunk)
            total_size += len(chunk)
            if total_size > Constants.MAX_BODY_SIZE:
                raise HTTPException(
                    status_code=413,
                    detail=f"Request too large. Max: {Constants.MAX_BODY_SIZE} bytes"
                )
        request._body = b"".join(chunks)
    
    # 2. Process request
    response: Response = await call_next(request)
    
    # 3. Security headers (sempre aplicar)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    
    # 4. HSTS (apenas em produção com HTTPS)
    if request.url.scheme == "https":
        response.headers["Strict-Transport-Security"] = (
            "max-age=31536000; includeSubDomains"
        )
    
    # 5. Frame protection (ajustar conforme necessidade)    
    response.headers["X-Frame-Options"] = "DENY"
    
    # 6. Permissions Policy (ajustar para PDV)
    response.headers["Permissions-Policy"] = (
        "camera=(self), "        # Permitir câmera para scanner
        "geolocation=(self), "   # Permitir localização se necessário
        "microphone=(), "
        "payment=(self), "
        "usb=(), "
        "interest-cohort=()"
    )
        
    if response.headers.get("content-type", "").startswith("text/html"):
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: https:; "
            "font-src 'self' data:; "
            "connect-src 'self'; "
            "frame-ancestors 'none'; "
            "base-uri 'self'; "
            "form-action 'self';"
        )
    else:
        response.headers["Content-Security-Policy"] = (
            "default-src 'none'; "
            "frame-ancestors 'none';"
        )
    
    if not request.url.path.startswith("/api/v1/admin"):
        response_time_ms = (time.perf_counter() - start_time) * 1000
        get_monitor().increment_request(response_time_ms)
        
        if response.status_code >= 400:
            get_monitor().increment_error()
    
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
    
    
if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        workers=4,
        loop="uvloop",
        http="httptools",
        # log_level="warning",
        limit_concurrency=1000,
        timeout_keep_alive=5
    )