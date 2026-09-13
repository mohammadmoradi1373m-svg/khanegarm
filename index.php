<?php
declare(strict_types=1);

/**
 * Hardened reverse proxy for owli.ir -> Supabase
 *
 * Security goals:
 * - Fixed upstream only (never an open proxy)
 * - Strict CORS allowlist
 * - Request-header allowlist
 * - No Authorization/API-key/body/response logging
 * - Bounded request/connection timeouts
 * - Safe response-header allowlist
 * - Public Storage assets may be browser-cached
 * - API responses are not cached
 */

define('SUPABASE_HOST', 'thovhvemaidbiekagome.supabase.co');
define('SUPABASE_BASE', 'https://' . SUPABASE_HOST);
// Public publishable key used by the frontend. Injecting it server-side makes the proxy robust
// against hosting layers that drop custom request headers such as `apikey`.
define('SUPABASE_ANON_KEY', 'sb_publishable_bX7ApIxbBzjXkQNiLw2wDw_m0TzJ6Wb');
define('MAX_REQUEST_BODY_BYTES', 8 * 1024 * 1024); // 8 MiB; product images are limited to 5 MiB.

$allowedOrigins = [
    'https://owli.ir',
    'https://www.owli.ir',
];

$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';

$allowedMethods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];

if (!in_array($method, $allowedMethods, true)) {
    http_response_code(405);
    header('Allow: GET, POST, PUT, PATCH, DELETE, OPTIONS');
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['error' => 'METHOD_NOT_ALLOWED'], JSON_UNESCAPED_UNICODE);
    exit;
}

/*
 * CORS:
 * - Allowed web origins receive ACAO.
 * - No-Origin requests are allowed for direct public assets and non-browser clients.
 * - A foreign Origin is rejected instead of being proxied.
 */
if ($origin !== '') {
    if (!in_array($origin, $allowedOrigins, true)) {
        http_response_code(403);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['error' => 'ORIGIN_NOT_ALLOWED'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    header('Access-Control-Allow-Origin: ' . $origin);
    header('Vary: Origin');
}

if ($method === 'OPTIONS') {
    $requestedMethod = strtoupper($_SERVER['HTTP_ACCESS_CONTROL_REQUEST_METHOD'] ?? '');
    if ($requestedMethod !== '' && !in_array($requestedMethod, ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'], true)) {
        http_response_code(405);
        exit;
    }

    header('Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS');
    header(
        'Access-Control-Allow-Headers: Authorization, apikey, Content-Type, Accept, Prefer, ' .
        'X-Client-Info, X-Upsert, Content-Range, Range, If-None-Match, If-Modified-Since, Cache-Control, X-Supabase-Api-Version'
    );
    header('Access-Control-Max-Age: 86400');
    http_response_code(204);
    exit;
}

/*
 * Build the upstream URL from the request path/query only.
 * The upstream host is fixed above, so this cannot become an open proxy.
 */
$requestUri = $_SERVER['REQUEST_URI'] ?? '/';
if ($requestUri === '' || $requestUri[0] !== '/') {
    $requestUri = '/' . ltrim($requestUri, '/');
}
$targetUrl = SUPABASE_BASE . $requestUri;

/*
 * Limit request bodies before reading php://input where Content-Length is known.
 * 8 MiB is above the site's current 5 MiB product-image limit.
 */
$contentLength = $_SERVER['CONTENT_LENGTH'] ?? '';
if ($contentLength !== '' && ctype_digit($contentLength)) {
    if ((int)$contentLength > MAX_REQUEST_BODY_BYTES) {
        http_response_code(413);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['error' => 'REQUEST_TOO_LARGE'], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

$body = '';
if (in_array($method, ['POST', 'PUT', 'PATCH', 'DELETE'], true)) {
    $body = file_get_contents('php://input');
    if ($body === false) {
        $body = '';
    }

    if (strlen($body) > MAX_REQUEST_BODY_BYTES) {
        http_response_code(413);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['error' => 'REQUEST_TOO_LARGE'], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

/*
 * Forward only headers required by the Supabase REST/Storage APIs.
 * Never forward arbitrary client headers.
 */
$headerMap = [
    'HTTP_AUTHORIZATION'       => 'Authorization',
    'CONTENT_TYPE'             => 'Content-Type',
    'HTTP_ACCEPT'              => 'Accept',
    'HTTP_PREFER'              => 'Prefer',
    'HTTP_X_CLIENT_INFO'       => 'X-Client-Info',
    'HTTP_X_UPSERT'            => 'X-Upsert',
    'HTTP_CONTENT_RANGE'       => 'Content-Range',
    'HTTP_RANGE'                => 'Range',
    'HTTP_IF_NONE_MATCH'       => 'If-None-Match',
    'HTTP_IF_MODIFIED_SINCE'   => 'If-Modified-Since',
    'HTTP_CACHE_CONTROL'       => 'Cache-Control',
    'HTTP_X_SUPABASE_API_VERSION' => 'X-Supabase-Api-Version',
];

$forwardHeaders = [];

foreach ($headerMap as $serverKey => $headerName) {
    if (isset($_SERVER[$serverKey]) && $_SERVER[$serverKey] !== '') {
        $forwardHeaders[] = $headerName . ': ' . $_SERVER[$serverKey];
    }
}

// Always provide the public Supabase key ourselves. It is intentionally a publishable key, not a secret.
$forwardHeaders[] = 'apikey: ' . SUPABASE_ANON_KEY;
$forwardHeaders[] = 'Host: ' . SUPABASE_HOST;
$forwardHeaders[] = 'Expect:';

$ch = curl_init($targetUrl);

curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HEADER => true,
    CURLOPT_CUSTOMREQUEST => $method,
    CURLOPT_HTTPHEADER => $forwardHeaders,
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2,
    CURLOPT_IPRESOLVE => CURL_IPRESOLVE_V4,
    CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
    CURLOPT_CONNECTTIMEOUT => 8,
    CURLOPT_TIMEOUT => 30,
    CURLOPT_FOLLOWLOCATION => false,
]);

if (in_array($method, ['POST', 'PUT', 'PATCH', 'DELETE'], true)) {
    curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
}

$response = curl_exec($ch);

if ($response === false) {
    /*
     * Do NOT expose curl_error() to the client.
     * Detailed transport errors belong in server-side monitoring only.
     */
    curl_close($ch);

    http_response_code(502);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(['error' => 'UPSTREAM_UNAVAILABLE'], JSON_UNESCAPED_UNICODE);
    exit;
}

$headerSize = curl_getinfo($ch, CURLINFO_HEADER_SIZE);
$statusCode = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

$responseHeaders = substr($response, 0, $headerSize);
$responseBody = substr($response, $headerSize);

/*
 * Public product/category assets are immutable in this project.
 * Keep this cache rule only for successful public Storage object GETs.
 */
$isStorageAsset =
    $method === 'GET' &&
    strpos($requestUri, '/storage/v1/object/public/') === 0;

$safeResponseHeaders = [
    'content-type'        => true,
    'content-length'      => true,
    'cache-control'       => true,
    'etag'                => true,
    'last-modified'       => true,
    'accept-ranges'       => true,
    'content-range'       => true,
    'content-encoding'    => true,
    'content-disposition' => true,
    'vary'                => true,
    'preference-applied'  => true,
];

$lines = preg_split("/\r\n|\n|\r/", $responseHeaders);
foreach ($lines as $line) {
    if ($line === '' || strpos($line, ':') === false) {
        continue;
    }

    [$name, $value] = explode(':', $line, 2);
    $lname = strtolower(trim($name));

    if (!isset($safeResponseHeaders[$lname])) {
        continue;
    }

    /*
     * We control cache policy for public Storage assets.
     * Do not pass through Supabase's shorter cache value in that case.
     */
    if ($isStorageAsset && $lname === 'cache-control') {
        continue;
    }

    header(trim($name) . ': ' . ltrim($value), false);
}

if ($origin !== '') {
    // Re-assert CORS on the final response after proxying upstream headers.
    header('Access-Control-Allow-Origin: ' . $origin);
    header('Vary: Origin', false);
}

if ($isStorageAsset && $statusCode >= 200 && $statusCode < 300) {
    header('Cache-Control: public, max-age=604800, immutable');
} elseif (!$isStorageAsset) {
    header('Cache-Control: no-store');
}

header('X-Content-Type-Options: nosniff');

http_response_code($statusCode);
echo $responseBody;
?>
