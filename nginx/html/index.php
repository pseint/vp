<?php
// =============================================================
// Página por defecto del servidor — se sirve cuando ningún vhost
// coincide con el Host de la petición.
// FIX: No exponer versión PHP, hostname, software, ni estado de
//      servicios internos (información de reconocimiento para atacantes).
// =============================================================

// Suprimir cualquier error PHP en output (producción)
error_reporting(0);

$date = date('Y-m-d H:i:s T');
?>
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Servidor de Hosting — Operativo</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
         background:#0f172a;color:#e2e8f0;min-height:100vh;
         display:flex;align-items:center;justify-content:center;padding:2rem}
    .card{background:#1e293b;border:1px solid #334155;border-radius:1.5rem;
          padding:3rem;max-width:520px;width:100%;text-align:center;
          box-shadow:0 25px 50px rgba(0,0,0,.5)}
    .status{display:inline-flex;align-items:center;gap:.5rem;
            background:#064e3b;color:#6ee7b7;padding:.4rem 1rem;
            border-radius:999px;font-size:.875rem;margin-bottom:2rem}
    .dot{width:8px;height:8px;background:#10b981;border-radius:50%;
         animation:pulse 2s infinite}
    @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
    h1{font-size:2rem;font-weight:700;margin-bottom:.5rem;
       background:linear-gradient(135deg,#60a5fa,#a78bfa);
       -webkit-background-clip:text;-webkit-text-fill-color:transparent}
    .subtitle{color:#94a3b8;margin-bottom:2rem}
    .info{background:#0f172a;border:1px solid #1e293b;border-radius:.75rem;
          padding:1.25rem;margin:1.5rem 0;text-align:left}
    .label{font-size:.75rem;color:#64748b;text-transform:uppercase;
           letter-spacing:.05em;margin-bottom:.5rem}
    .msg{font-size:.9rem;color:#94a3b8;line-height:1.6}
    .footer{margin-top:2rem;font-size:.75rem;color:#475569}
  </style>
</head>
<body>
  <div class="card">
    <div class="status">
      <span class="dot"></span>
      Servidor operativo
    </div>
    <h1>🚀 Hosting Server</h1>
    <p class="subtitle">Oracle VPS Free — ARM64 · Docker Stack</p>

    <div class="info">
      <div class="label">Este dominio no está configurado</div>
      <p class="msg">
        Si eres el administrador del servidor, crea un virtual host con:<br>
        <code style="color:#60a5fa">make add-site DOMAIN=tudominio.com</code>
      </p>
    </div>

    <div class="footer">
      Stack: Traefik v3 · PowerDNS · Nginx · PHP-FPM · MariaDB · Redis · Portainer<br>
      <?= htmlspecialchars($date) ?>
    </div>
  </div>
</body>
</html>
