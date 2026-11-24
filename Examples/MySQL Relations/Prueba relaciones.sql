-- BASE LOCAL DE PRUEBAS: braket_relations_demo. Todos los datos son ficticios.
-- Chevron a la derecha de user_id: tarjeta con la fila completa y su footer.
-- ⌘+clic en user_id o en la fila: abrir el registro en una nueva consulta.
SELECT * FROM UserMappings ORDER BY um_id;

-- Dos relaciones por fila: organización y responsable. Las columnas NULL no se navegan.
SELECT * FROM Users ORDER BY id;

-- Clave compuesta: (organization_id, department_code) identifica el departamento correcto.
-- OPS existe en dos organizaciones diferentes para comprobar que se usan ambas columnas.
SELECT * FROM Employees ORDER BY id;

-- 120 pedidos: paginación, dos enlaces a Users y edición de números/enum/fechas.
SELECT * FROM Orders ORDER BY id;

-- Vista angosta: el chevron debe seguir visible sin ensanchar user_id.
SELECT um_id, user_id FROM UserMappings ORDER BY um_id;

-- Listas locales de Braket combinadas con relaciones.
SET LIST IDS_DEMO = [1001, 1002, 9007199254740993];
SELECT * FROM Users WHERE id IN ({{IDS_DEMO}});
