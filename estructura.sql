-- Proyecto Capstone / PostgreSQL / PetStop (datos exclusivamente sintéticos).
-- Preparación, UNA VEZ y fuera de una transacción:
-- CREATE DATABASE capstone_project;
-- Conectarse a capstone_project y ejecutar este archivo completo.
-- Se recrea únicamente el esquema académico petstop_capstone para reproducibilidad.
BEGIN;
DROP SCHEMA IF EXISTS petstop_capstone CASCADE;
CREATE SCHEMA petstop_capstone;
SET search_path TO petstop_capstone, public;

CREATE TABLE clientes (
    cliente_id INTEGER PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL,
    email VARCHAR(120) NOT NULL UNIQUE,
    ciudad VARCHAR(50) NOT NULL
);
CREATE TABLE productos (
    producto_id INTEGER PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL,
    categoria VARCHAR(40) NOT NULL,
    precio_catalogo NUMERIC(12,2) NOT NULL CHECK (precio_catalogo > 0)
);
INSERT INTO clientes
SELECT n, 'Cliente ficticio ' || LPAD(n::TEXT, 2, '0'),
       'cliente' || n || '@example.invalid',
       CASE WHEN n % 3 = 0 THEN 'Rosario' WHEN n % 3 = 1 THEN 'Buenos Aires' ELSE 'Córdoba' END
FROM generate_series(1, 12) AS g(n);
INSERT INTO productos VALUES
(1, 'Alimento perro 3 kg', 'Alimentos', 12000.00),
(2, 'Alimento gato 1 kg', 'Alimentos', 8000.00),
(3, 'Snack dental', 'Alimentos', 3000.00),
(4, 'Correa reforzada', 'Accesorios', 6000.00),
(5, 'Collar ajustable', 'Accesorios', 4500.00),
(6, 'Juguete cuerda', 'Accesorios', 3500.00),
(7, 'Shampoo neutro', 'Higiene', 5500.00),
(8, 'Arena sanitaria', 'Higiene', 7000.00),
(9, 'Cepillo premium', 'Higiene', 9000.00);

-- Staging conserva los defectos para que la limpieza sea auditable.
CREATE TABLE pedidos_raw (
    fila_origen INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pedido_id INTEGER,
    cliente_id INTEGER,
    producto_id INTEGER,
    fecha DATE,
    fecha_confirmacion DATE,
    cantidad INTEGER,
    precio_unitario NUMERIC(12,2),
    descuento NUMERIC(5,4),
    estado VARCHAR(30)
);
WITH meses(mes, cantidad_pedidos) AS (
    VALUES (1,12), (2,16), (3,18), (4,22), (5,24), (6,28)
), base AS (
    SELECT mes, dia, ROW_NUMBER() OVER (ORDER BY mes,dia)::INTEGER AS n
    FROM meses CROSS JOIN LATERAL generate_series(1,cantidad_pedidos) AS s(dia)
)
INSERT INTO pedidos_raw(pedido_id,cliente_id,producto_id,fecha,fecha_confirmacion,
                        cantidad,precio_unitario,descuento,estado)
SELECT n, 1 + (n*3 % 10), 1 + (n*5 % 8),
       CASE WHEN n % 31 = 0 THEN NULL ELSE make_date(2026,mes,dia) END,
       make_date(2026,mes,dia),
       1 + n % 3,
       CASE WHEN n % 17 = 0 THEN NULL ELSE p.precio_catalogo END,
       CASE WHEN n % 7 = 0 THEN NULL WHEN n % 5 = 0 THEN 0.10 ELSE 0 END,
       CASE WHEN n % 11 = 0 THEN ' CANCELADO ' ELSE ' Completado ' END
FROM base JOIN productos AS p ON p.producto_id = 1 + (n*5 % 8);
-- Tres defectos añadidos intencionalmente: duplicado, cantidad inválida y fecha irrecuperable.
INSERT INTO pedidos_raw(pedido_id,cliente_id,producto_id,fecha,fecha_confirmacion,
                        cantidad,precio_unitario,descuento,estado)
SELECT pedido_id,cliente_id,producto_id,fecha,fecha_confirmacion,cantidad,
       precio_unitario,descuento,estado FROM pedidos_raw WHERE pedido_id=5;
INSERT INTO pedidos_raw(pedido_id,cliente_id,producto_id,fecha,fecha_confirmacion,
                        cantidad,precio_unitario,descuento,estado) VALUES
(121,1,1,DATE '2026-06-29',DATE '2026-06-29',0,12000,0,'completado'),
(122,2,2,NULL,NULL,1,8000,0,'completado');

-- Elegimos la primera copia del registro: los duplicados generados son idénticos.
-- En producción, un conflicto entre copias requeriría conciliación, no descarte ciego.
CREATE VIEW preparacion AS
SELECT r.*, ROW_NUMBER() OVER (PARTITION BY pedido_id ORDER BY fila_origen) AS copia,
       COALESCE(r.fecha, r.fecha_confirmacion) AS fecha_limpia,
       COALESCE(r.precio_unitario, p.precio_catalogo) AS precio_limpio,
       COALESCE(r.descuento, 0::NUMERIC) AS descuento_limpio,
       LOWER(BTRIM(r.estado)) AS estado_limpio
FROM pedidos_raw AS r
LEFT JOIN productos AS p ON p.producto_id=r.producto_id;

CREATE TABLE rechazos AS
SELECT fila_origen, pedido_id,
       CASE WHEN copia > 1 THEN 'duplicado'
            WHEN fecha_limpia IS NULL THEN 'fecha no recuperable'
            WHEN cantidad IS NULL OR cantidad <= 0 THEN 'cantidad no válida'
            WHEN precio_limpio IS NULL OR precio_limpio <= 0 THEN 'precio no válido'
            WHEN descuento_limpio NOT BETWEEN 0 AND 1 THEN 'descuento no válido'
            WHEN estado_limpio NOT IN ('completado','cancelado') THEN 'estado no válido'
            WHEN NOT EXISTS (SELECT 1 FROM clientes c WHERE c.cliente_id=preparacion.cliente_id)
                THEN 'cliente inexistente'
       END AS motivo
FROM preparacion
WHERE copia>1 OR fecha_limpia IS NULL OR cantidad IS NULL OR cantidad<=0
   OR precio_limpio IS NULL OR precio_limpio<=0
   OR descuento_limpio NOT BETWEEN 0 AND 1
   OR estado_limpio NOT IN ('completado','cancelado')
   OR NOT EXISTS (SELECT 1 FROM clientes c WHERE c.cliente_id=preparacion.cliente_id);

CREATE TABLE pedidos (
    pedido_id INTEGER PRIMARY KEY,
    cliente_id INTEGER NOT NULL REFERENCES clientes(cliente_id),
    producto_id INTEGER NOT NULL REFERENCES productos(producto_id),
    fecha DATE NOT NULL,
    cantidad INTEGER NOT NULL CHECK (cantidad > 0),
    precio_unitario NUMERIC(12,2) NOT NULL CHECK (precio_unitario > 0),
    descuento NUMERIC(5,4) NOT NULL CHECK (descuento BETWEEN 0 AND 1),
    estado VARCHAR(15) NOT NULL CHECK (estado IN ('completado','cancelado')),
    precio_recuperado BOOLEAN NOT NULL,
    fecha_recuperada BOOLEAN NOT NULL,
    importe_neto NUMERIC(14,2) GENERATED ALWAYS AS
        (ROUND(cantidad * precio_unitario * (1 - descuento),2)) STORED
);
INSERT INTO pedidos(pedido_id,cliente_id,producto_id,fecha,cantidad,precio_unitario,
                    descuento,estado,precio_recuperado,fecha_recuperada)
SELECT p.pedido_id,p.cliente_id,p.producto_id,p.fecha_limpia,p.cantidad,p.precio_limpio,
       p.descuento_limpio,p.estado_limpio,p.precio_unitario IS NULL,p.fecha IS NULL
FROM preparacion AS p
WHERE NOT EXISTS (SELECT 1 FROM rechazos AS r WHERE r.fila_origen=p.fila_origen);

-- Solo pedidos completados forman la base de ingresos; el precio histórico queda en el pedido.
CREATE VIEW ventas_validas AS
SELECT v.pedido_id,v.cliente_id,c.nombre AS cliente,c.ciudad,v.producto_id,
       p.nombre AS producto,p.categoria,v.fecha,v.cantidad,v.importe_neto,
       v.precio_recuperado,v.fecha_recuperada
FROM pedidos AS v
JOIN clientes AS c ON c.cliente_id=v.cliente_id
JOIN productos AS p ON p.producto_id=v.producto_id
WHERE v.estado='completado';
CREATE INDEX idx_pedidos_fecha ON pedidos(fecha);
CREATE INDEX idx_pedidos_cliente ON pedidos(cliente_id);
CREATE INDEX idx_pedidos_producto ON pedidos(producto_id);
COMMIT;

-- Conciliación de filas y nulos. Los 3 rechazos no se borran del staging.
SELECT (SELECT COUNT(*) FROM pedidos_raw) AS filas_origen,
       (SELECT COUNT(*) FROM pedidos) AS pedidos_limpios,
       (SELECT COUNT(*) FROM rechazos) AS rechazadas,
       (SELECT COUNT(*) FROM ventas_validas) AS ventas_completadas;
