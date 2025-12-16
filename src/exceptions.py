

class DatabaseError(Exception):
    
    def __init__(self, detail: str, code: int = None, log_msg: str = None):
        super().__init__(detail)
        self.detail = detail
        self.code = code
        self.log_msg = log_msg

    def __str__(self):
        base = f"[DatabaseError] {self.detail}"
        if self.code: base += f" (code: {self.code})"
        return base
