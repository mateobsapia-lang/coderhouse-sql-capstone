SET search_path TO petstop_capstone, public;

-- Q1. ¿En qué cinco clientes concentrar una prueba de fidelización?
-- No incluimos cancelaciones ni inferimos rentabilidad sin costos.
SELECT c.cliente_id,c.nombre,COUNT(*) AS pedidos,
       SUM(v.importe_neto) AS gasto_total,
       ROUND(100*SUM(v.importe_neto)/SUM(SUM(v.importe_neto)) OVER (),2) AS porcentaje_ingresos
FROM clientes AS c JOIN ventas_validas AS v ON v.cliente_id=c.cliente_id
GROUP BY c.cliente_id,c.nombre
ORDER BY gasto_total DESC,c.cliente_id LIMIT 5;

-- Q2. ¿Cómo evolucionan los ingresos mensuales y cuánto depende del volumen?
-- Calendario explícito para que un mes sin ventas sea cero, no desaparezca.
WITH calendario AS (
    SELECT generate_series(DATE '2026-01-01',DATE '2026-06-01',INTERVAL '1 month')::DATE AS mes
), ventas_mes AS (
    SELECT DATE_TRUNC('month',v.fecha)::DATE AS mes,COUNT(*) AS pedidos,
           SUM(v.importe_neto) AS ventas
    FROM ventas_validas AS v GROUP BY DATE_TRUNC('month',v.fecha)::DATE
), serie AS (
    SELECT c.mes,COALESCE(v.pedidos,0) AS pedidos,COALESCE(v.ventas,0) AS ventas
    FROM calendario AS c LEFT JOIN ventas_mes AS v ON v.mes=c.mes
)
SELECT mes,pedidos,ventas,ROUND(ventas/NULLIF(pedidos,0),2) AS ticket_promedio,
       ROUND(100*(ventas-LAG(ventas) OVER (ORDER BY mes)) /
           NULLIF(LAG(ventas) OVER (ORDER BY mes),0),2) AS variacion_porcentual,
       SUM(ventas) OVER (ORDER BY mes ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS acumulado
FROM serie ORDER BY mes;

-- Q3. ¿Qué tres productos requieren investigar su baja rotación?
-- Partir del catálogo conserva también los productos con cero ventas.
SELECT p.producto_id,p.nombre,COALESCE(SUM(v.cantidad),0) AS unidades,
       COUNT(v.pedido_id) AS pedidos,COALESCE(SUM(v.importe_neto),0) AS ingresos
FROM productos AS p LEFT JOIN ventas_validas AS v ON v.producto_id=p.producto_id
GROUP BY p.producto_id,p.nombre ORDER BY unidades,p.producto_id LIMIT 3;

-- Q4. ¿Qué pedidos lideran por importe dentro de cada categoría?
-- RANK conserva empates; pedido_id ordena la salida sin romperlos en la ventana.
SELECT categoria,pedido_id,fecha,cliente,importe_neto,
       RANK() OVER (PARTITION BY categoria ORDER BY importe_neto DESC) AS ranking_categoria
FROM ventas_validas ORDER BY categoria,ranking_categoria,pedido_id;

-- Q5. ¿Qué categorías lideran cada mes y cuáles superan su promedio mensual?
-- Se cruzan 6 meses por 3 categorías: el promedio incluye meses sin ventas.
WITH calendario AS (
    SELECT generate_series(DATE '2026-01-01',DATE '2026-06-01',INTERVAL '1 month')::DATE AS mes
), categorias AS (SELECT DISTINCT p.categoria FROM productos AS p),
ventas_mensuales AS (
    SELECT c.mes,k.categoria,COALESCE(SUM(v.importe_neto),0) AS ventas
    FROM calendario AS c CROSS JOIN categorias AS k
    LEFT JOIN ventas_validas AS v ON DATE_TRUNC('month',v.fecha)::DATE=c.mes AND v.categoria=k.categoria
    GROUP BY c.mes,k.categoria
), metricas_ventana AS (
    SELECT mes,categoria,ventas,
           RANK() OVER (PARTITION BY mes ORDER BY ventas DESC) AS ranking_mes,
           SUM(ventas) OVER (PARTITION BY categoria ORDER BY mes
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS acumulado,
           AVG(ventas) OVER (PARTITION BY categoria) AS promedio
    FROM ventas_mensuales
)
SELECT mes,categoria,ventas,ranking_mes,acumulado,ROUND(promedio,2) AS promedio_mensual,
       CASE WHEN ventas>promedio THEN 'Por encima' WHEN ventas<promedio THEN 'Por debajo'
            ELSE 'Igual al promedio' END AS comparativa
FROM metricas_ventana ORDER BY mes,ranking_mes,categoria;

-- Q6. ¿Cuántos clientes registrados nunca completaron una compra?
-- Un pedido cancelado no demuestra conversión. No publicar datos de contacto.
SELECT c.cliente_id,c.nombre,COALESCE(SUM(v.importe_neto),0) AS gasto_total
FROM clientes AS c LEFT JOIN ventas_validas AS v ON v.cliente_id=c.cliente_id
GROUP BY c.cliente_id,c.nombre HAVING COUNT(v.pedido_id)=0 ORDER BY c.cliente_id;

-- Q7. ¿Cuánto dependen los resultados de la recuperación de precios faltantes?
-- Sensibilidad: separamos importes imputados; no los presentamos como observados.
SELECT COUNT(*) AS pedidos_completados,SUM(cantidad) AS unidades,
       SUM(importe_neto) AS ingreso_neto,
       COALESCE(SUM(importe_neto) FILTER (WHERE precio_recuperado),0) AS ingreso_con_precio_recuperado,
       ROUND(100*COALESCE(SUM(importe_neto) FILTER (WHERE precio_recuperado),0)/SUM(importe_neto),2)
           AS porcentaje_ingreso_recuperado,
       COUNT(*) FILTER (WHERE fecha_recuperada) AS fechas_recuperadas
FROM ventas_validas;

-- Q8. ¿Qué categorías aportan más ingresos? No se denomina margen: no hay costos.
SELECT categoria,SUM(cantidad) AS unidades,SUM(importe_neto) AS ingresos,
       ROUND(100*SUM(importe_neto)/SUM(SUM(importe_neto)) OVER (),2) AS porcentaje
FROM ventas_validas GROUP BY categoria ORDER BY ingresos DESC,categoria;
