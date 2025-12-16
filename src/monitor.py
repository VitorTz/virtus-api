from datetime import datetime, timezone
from typing import Dict, List, Optional
from dataclasses import dataclass
from collections import deque
import asyncio
import threading
import time
import psutil
import gc
import os


@dataclass
class MetricSnapshot:
    
    timestamp: float
    value: float
    
    def to_dict(self) -> dict:
        return {"timestamp": self.timestamp, "value": self.value}


class RollingMetrics:
    
    def __init__(self, max_size: int = 288):
        self._data: deque = deque(maxlen=max_size)
        self._lock = threading.RLock()
    
    def add(self, value: float, timestamp: Optional[float] = None):
        """Adiciona um valor ao histórico"""
        ts = timestamp or time.time()
        with self._lock:
            self._data.append(MetricSnapshot(ts, value))
    
    def get_all(self) -> List[Dict]:
        """Retorna todo o histórico"""
        with self._lock:
            return [snap.to_dict() for snap in self._data]
    
    def get_recent(self, seconds: int = 60) -> List[Dict]:
        """Retorna valores dos últimos N segundos"""
        cutoff = time.time() - seconds
        with self._lock:
            return [snap.to_dict() for snap in self._data if snap.timestamp >= cutoff]
    
    def get_stats(self) -> Dict[str, float]:
        """Calcula estatísticas do histórico"""
        with self._lock:
            if not self._data:
                return {"min": 0, "max": 0, "avg": 0, "current": 0}
            
            values = [snap.value for snap in self._data]
            return {
                "min": round(min(values), 2),
                "max": round(max(values), 2),
                "avg": round(sum(values) / len(values), 2),
                "current": round(values[-1], 2)
            }
    
    def clear(self):
        """Limpa o histórico"""
        with self._lock:
            self._data.clear()


class SystemMonitor:
    """Monitor avançado de recursos do sistema para FastAPI"""
    
    def __init__(self, history_size: int = 288, enable_gc_on_read: bool = False):
        """
        Args:
            history_size: Tamanho máximo do histórico de métricas (padrão: 288 = 24h com coleta a cada 5min)
            enable_gc_on_read: Se True, força GC ao ler memória (impacta performance)
        """
        self.process = psutil.Process(os.getpid())
        self.start_time = time.time()
        self.enable_gc_on_read = enable_gc_on_read
        
        # Contadores thread-safe
        self._lock = threading.RLock()
        self._request_count = 0
        self._error_count = 0
        self._peak_memory = 0
        self._peak_cpu = 0
        
        # Históricos com rolling window
        self.memory_history = RollingMetrics(history_size)
        self.cpu_history = RollingMetrics(history_size)
        self.response_times = RollingMetrics(min(history_size, 1000))  # Últimas 1000 requests
        
        # Cache para evitar leituras excessivas
        self._cache = {}
        self._cache_ttl = 1.0  # 1 segundo de TTL
        
        # Inicializa histórico
        self._update_history_internal()
    
    def _get_cached(self, key: str, fetch_func):
        """Sistema de cache simples para métricas"""
        now = time.time()
        
        if key in self._cache:
            cached_time, cached_value = self._cache[key]
            if now - cached_time < self._cache_ttl:
                return cached_value
        
        value = fetch_func()
        self._cache[key] = (now, value)
        return value
    
    def get_memory_info(self) -> Dict:
        """Retorna informações detalhadas de memória com cache"""
        def fetch():
            try:
                # Memória do processo
                memory_info = self.process.memory_info()
                memory_percent = self.process.memory_percent()
                
                # Memória do sistema
                system_memory = psutil.virtual_memory()
                
                # GC apenas se habilitado
                gc_collected = 0
                if self.enable_gc_on_read:
                    gc_collected = gc.collect()
                
                # Informações do Python
                python_objects = len(gc.get_objects())
                gc_stats = gc.get_stats() if hasattr(gc, 'get_stats') else []
                
                # Atualiza pico
                with self._lock:
                    if memory_info.rss > self._peak_memory:
                        self._peak_memory = memory_info.rss
                
                return {
                    "process": {
                        "rss_bytes": memory_info.rss,
                        "vms_bytes": memory_info.vms,
                        "rss_mb": round(memory_info.rss / 1024 / 1024, 2),
                        "vms_mb": round(memory_info.vms / 1024 / 1024, 2),
                        "percent": round(memory_percent, 2),
                        "peak_mb": round(self._peak_memory / 1024 / 1024, 2)
                    },
                    "system": {
                        "total_mb": round(system_memory.total / 1024 / 1024, 2),
                        "available_mb": round(system_memory.available / 1024 / 1024, 2),
                        "used_mb": round(system_memory.used / 1024 / 1024, 2),
                        "percent": round(system_memory.percent, 2)
                    },
                    "python": {
                        "objects_count": python_objects,
                        "gc_collected": gc_collected,
                        "gc_enabled": gc.isenabled(),
                        "gc_thresholds": gc.get_threshold(),
                        "gc_count": gc.get_count()
                    },
                    "history_stats": self.memory_history.get_stats()
                }
            except Exception as e:
                print(f"Failed to get memory info: {e}")                
                return {"error": str(e)}
        
        return self._get_cached("memory", fetch)
    
    def get_cpu_info(self) -> Dict:
        """Retorna informações detalhadas de CPU com cache"""
        def fetch():
            try:
                # CPU do processo (sem bloqueio)
                cpu_percent = self.process.cpu_percent(interval=0)
                cpu_times = self.process.cpu_times()
                
                # CPU do sistema
                system_cpu = psutil.cpu_percent(interval=0, percpu=True)
                cpu_freq = psutil.cpu_freq()
                cpu_count = psutil.cpu_count(logical=True)
                cpu_count_physical = psutil.cpu_count(logical=False)
                
                # Atualiza pico
                with self._lock:
                    if cpu_percent > self._peak_cpu:
                        self._peak_cpu = cpu_percent
                
                # Load average (Unix/Linux)
                load_avg = [0.0, 0.0, 0.0]
                try:
                    load_avg = list(os.getloadavg())
                except (AttributeError, OSError):
                    pass  # Windows não tem load average
                
                return {
                    "process": {
                        "percent": round(cpu_percent, 2),
                        "user_time": round(cpu_times.user, 2),
                        "system_time": round(cpu_times.system, 2),
                        "peak_percent": round(self._peak_cpu, 2),
                        "num_threads": self.process.num_threads()
                    },
                    "system": {
                        "percent_total": round(sum(system_cpu) / len(system_cpu), 2) if system_cpu else 0,
                        "percent_per_core": [round(cpu, 2) for cpu in system_cpu],
                        "core_count_logical": cpu_count,
                        "core_count_physical": cpu_count_physical,
                        "frequency_current_mhz": round(cpu_freq.current, 2) if cpu_freq else 0,
                        "frequency_min_mhz": round(cpu_freq.min, 2) if cpu_freq and cpu_freq.min else 0,
                        "frequency_max_mhz": round(cpu_freq.max, 2) if cpu_freq and cpu_freq.max else 0,
                        "load_average": {
                            "1min": round(load_avg[0], 2),
                            "5min": round(load_avg[1], 2),
                            "15min": round(load_avg[2], 2)
                        }
                    },
                    "history_stats": self.cpu_history.get_stats()
                }
            except Exception as e:
                print(f"Failed to get CPU info: {e}")
                return {"error": str(e)}
        
        return self._get_cached("cpu", fetch)
    
    def get_disk_info(self) -> Dict:
        """Retorna informações de disco"""
        try:
            disk_usage = psutil.disk_usage('/')
            disk_io = psutil.disk_io_counters()
            
            return {
                "usage": {
                    "total_gb": round(disk_usage.total / 1024 / 1024 / 1024, 2),
                    "used_gb": round(disk_usage.used / 1024 / 1024 / 1024, 2),
                    "free_gb": round(disk_usage.free / 1024 / 1024 / 1024, 2),
                    "percent": round(disk_usage.percent, 2)
                },
                "io": {
                    "read_mb": round(disk_io.read_bytes / 1024 / 1024, 2) if disk_io else 0,
                    "write_mb": round(disk_io.write_bytes / 1024 / 1024, 2) if disk_io else 0,
                    "read_count": disk_io.read_count if disk_io else 0,
                    "write_count": disk_io.write_count if disk_io else 0
                }
            }
        except Exception as e:
            print(f"Failed to get disk info: {e}")
            return {"error": str(e)}
    
    def get_network_info(self) -> Dict:
        """Retorna informações de rede"""
        try:
            net_io = psutil.net_io_counters()
            
            # Conexões do processo (pode ser lento)
            try:
                net_connections = len(self.process.connections())
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                net_connections = 0
            
            return {
                "io": {
                    "bytes_sent_mb": round(net_io.bytes_sent / 1024 / 1024, 2),
                    "bytes_recv_mb": round(net_io.bytes_recv / 1024 / 1024, 2),
                    "packets_sent": net_io.packets_sent,
                    "packets_recv": net_io.packets_recv,
                    "errors_in": net_io.errin,
                    "errors_out": net_io.errout,
                    "drops_in": net_io.dropin,
                    "drops_out": net_io.dropout
                },
                "connections": {
                    "active": net_connections
                }
            }
        except Exception as e:
            print(f"Failed to get network info: {e}")
            return {"error": str(e)}
    
    def get_process_info(self) -> Dict:
        """Retorna informações gerais do processo"""
        try:
            uptime = time.time() - self.start_time
            
            with self._lock:
                request_count = self._request_count
                error_count = self._error_count
            
            # Taxa de erro
            error_rate = (error_count / request_count * 100) if request_count > 0 else 0
            
            # Requests por segundo (baseado em todo o uptime)
            rps = request_count / uptime if uptime > 0 else 0
            
            return {
                "pid": self.process.pid,
                "name": self.process.name(),
                "uptime_seconds": round(uptime, 2),
                "uptime_formatted": self._format_uptime(uptime),
                "status": self.process.status(),
                "created": datetime.fromtimestamp(
                    self.process.create_time(), timezone.utc
                ).isoformat(),
                "threads": self.process.num_threads(),
                "file_descriptors": self._get_fd_count(),
                "requests": {
                    "total": request_count,
                    "errors": error_count,
                    "error_rate_percent": round(error_rate, 2),
                    "requests_per_second": round(rps, 2)
                },
                "response_time_stats": self.response_times.get_stats()
            }
        except Exception as e:
            print(f"Failed to get process info: {e}")
            return {"error": str(e)}
    
    def get_all_metrics(self) -> Dict:
        """Retorna todas as métricas em um único dict"""
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "process": self.get_process_info(),
            "memory": self.get_memory_info(),
            "cpu": self.get_cpu_info(),
            "disk": self.get_disk_info(),
            "network": self.get_network_info()
        }
    
    def increment_request(self, response_time_ms: Optional[float] = None):
        """
        Incrementa contador de requests e registra tempo de resposta
        
        Args:
            response_time_ms: Tempo de resposta em milissegundos
        """
        with self._lock:
            self._request_count += 1
        
        if response_time_ms is not None:
            self.response_times.add(response_time_ms)
    
    def increment_error(self):
        """Incrementa contador de erros"""
        with self._lock:
            self._error_count += 1
    
    def update_history(self):
        """Atualiza histórico de uso (chamado periodicamente por background task)"""
        self._update_history_internal()
    
    def _update_history_internal(self):
        """Implementação interna da atualização de histórico"""
        try:
            # Usa interval=0 para não bloquear
            cpu_percent = self.process.cpu_percent(interval=0)
            memory_mb = self.process.memory_info().rss / 1024 / 1024
            
            timestamp = time.time()
            
            self.cpu_history.add(cpu_percent, timestamp)
            self.memory_history.add(memory_mb, timestamp)
            
        except Exception as e:
            print(f"Failed to update history: {e}")
    
    def get_history(self, metric: str = "all", seconds: Optional[int] = None) -> Dict:
        """
        Retorna histórico de métricas
        
        Args:
            metric: "memory", "cpu", "response_time" ou "all"
            seconds: Se especificado, retorna apenas últimos N segundos
        """
        get_func = lambda h: h.get_all() if seconds is None else h.get_recent(seconds)
        
        if metric == "memory":
            return {"memory": get_func(self.memory_history)}
        elif metric == "cpu":
            return {"cpu": get_func(self.cpu_history)}
        elif metric == "response_time":
            return {"response_time": get_func(self.response_times)}
        else:
            return {
                "memory": get_func(self.memory_history),
                "cpu": get_func(self.cpu_history),
                "response_time": get_func(self.response_times)
            }
    
    def reset_counters(self):
        """Reseta contadores de requests e erros"""
        with self._lock:
            self._request_count = 0
            self._error_count = 0
            self._peak_memory = 0
            self._peak_cpu = 0
    
    def clear_history(self):
        """Limpa todo o histórico de métricas"""
        self.memory_history.clear()
        self.cpu_history.clear()
        self.response_times.clear()
    
    def _get_fd_count(self) -> int:
        """Retorna contagem de file descriptors (Unix) ou N/A"""
        try:
            if hasattr(self.process, 'num_fds'):
                return self.process.num_fds()
            return 0
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            return 0
    
    def _format_uptime(self, seconds: float) -> str:
        """Formata o uptime em formato legível"""
        days = int(seconds // 86400)
        hours = int((seconds % 86400) // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        
        parts = []
        if days > 0:
            parts.append(f"{days}d")
        if hours > 0 or days > 0:
            parts.append(f"{hours}h")
        if minutes > 0 or hours > 0 or days > 0:
            parts.append(f"{minutes}m")
        parts.append(f"{secs}s")
        
        return " ".join(parts)


_monitor_instance: Optional[SystemMonitor] = None


def get_monitor() -> SystemMonitor:
    """Retorna instância singleton do monitor"""
    global _monitor_instance
    if _monitor_instance is None:
        _monitor_instance = SystemMonitor()
    return _monitor_instance


async def periodic_update():
    while True:
        get_monitor().update_history()
        await asyncio.sleep(300)