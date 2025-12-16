from fastapi import Request
from fastapi.responses import Response
from src.constants import Constants


def add_security_headers(request: Request, response: Response) -> None:    
    response.headers["X-Content-Type-Options"] = "nosniff"    
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"    
    response.headers["Permissions-Policy"] = Constants.PERMISSIONS_POLICY_HEADER
    
    if Constants.IS_PRODUCTION:
        response.headers["Strict-Transport-Security"] = ("max-age=31536000; includeSubDomains; preload")
        
    response.headers["Content-Security-Policy"] = (
        "default-src 'none'; "
        "frame-ancestors 'none';"
    )    
    
    is_sensitive = any(request.url.path.startswith(path) for path in Constants.SENSITIVE_PATHS)
    
    if is_sensitive:
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    else:
        if request.url.path.startswith("/static/"):
            response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        else:
            response.headers["Cache-Control"] = "no-cache"
