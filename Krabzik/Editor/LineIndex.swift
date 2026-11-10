import Foundation

/// Comienzos de línea en desplazamientos UTF-16, que son los que usa AppKit para
/// selecciones y ediciones.
///
/// Los comienzos se guardan absolutos hasta `pivot`; desde ahí falta sumarles `pending`.
/// Así una edición solo tiene que materializar las entradas entre el pivote anterior y el
/// punto editado —escribiendo seguido, ninguna— en vez de recorrer las 76.000 que puede
/// tener un archivo de 5 MB. Medido antes de esto: 7,25 ms por pulsación, el 86 % del
/// costo de escribir una letra. Ver docs/specs/C11-rendimiento-editor.md.
struct LineIndex {
    private var stored: [Int]
    private var pivot: Int
    private var pending: Int

    init(_ text: String) {
        stored = [0] + text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
        pivot = stored.count
        pending = 0
    }

    /// Cantidad de líneas.
    var count: Int { stored.count }

    /// Comienzo de la línea `line`, contando desde 0.
    func start(of line: Int) -> Int { stored[line] + (line >= pivot ? pending : 0) }

    /// Todos los comienzos, con el desplazamiento aplicado. Copia el arreglo, así que es
    /// para pruebas y depuración: el camino caliente usa `start(of:)` y `line(at:)`.
    var starts: [Int] {
        guard pending != 0 else { return stored }
        var copy = stored
        for index in pivot ..< copy.count { copy[index] += pending }
        return copy
    }

    /// Línea que contiene `offset`, contando desde 0.
    func line(at offset: Int) -> Int { max(0, upperBound(offset) - 1) }

    /// Primer índice cuyo comienzo es mayor que `offset`. El desplazamiento pendiente
    /// conserva el orden, así que la bisección sigue valiendo.
    private func upperBound(_ offset: Int) -> Int {
        var low = 0, high = stored.count
        while low < high {
            let mid = (low + high) / 2
            if start(of: mid) <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    mutating func replace(_ range: NSRange, with text: String) {
        let delta = text.utf16.count - range.length
        let first = upperBound(range.location)
        let afterEnd = upperBound(NSMaxRange(range))
        var inserted: [Int] = []
        for (offset, unit) in text.utf16.enumerated() where unit == 10 {
            inserted.append(range.location + offset + 1)
        }
        // Todo lo anterior a la edición queda absoluto; la cola hereda el desplazamiento.
        movePivot(to: afterEnd)
        stored.replaceSubrange(first ..< afterEnd, with: inserted)
        pivot = first + inserted.count
        pending += delta
    }

    /// Mueve el pivote, materializando las entradas que cruza.
    private mutating func movePivot(to target: Int) {
        if pending != 0 {
            if target > pivot {
                for index in pivot ..< target { stored[index] += pending }
            } else if target < pivot {
                for index in target ..< pivot { stored[index] -= pending }
            }
        }
        pivot = target
    }
}
