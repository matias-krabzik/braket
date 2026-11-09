<?php

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: http://127.0.0.1:18766');

$products = [
    ['id' => 1, 'name' => 'Café', 'price' => 8500],
    ['id' => 2, 'name' => 'Cuaderno', 'price' => 4200],
    ['id' => 3, 'name' => 'Lápiz', 'price' => 900],
];

echo json_encode($products, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
