// DataWheel — 格式定义
import SwiftUI

struct DataFormat: Identifiable, Hashable {
    let id: String          // 引擎参数
    let label: String       // 扇区显示
    let color: Color
    let desc: String

    static let all: [DataFormat] = [
        DataFormat(id: "csv",     label: "CSV",     color: Color(hex: 0xF59E0B), desc: "逗号分隔文本"),
        DataFormat(id: "tsv",     label: "TSV",     color: Color(hex: 0xF97316), desc: "制表符文本"),
        DataFormat(id: "txt",     label: "TXT",     color: Color(hex: 0xD97706), desc: "文本（自动分列）"),
        DataFormat(id: "xlsx",    label: "XLSX",    color: Color(hex: 0x16A34A), desc: "Excel 工作簿"),
        DataFormat(id: "dta",     label: "DTA",     color: Color(hex: 0x0891B2), desc: "Stata 数据"),
        DataFormat(id: "rds",     label: "RDS",     color: Color(hex: 0x3B82F6), desc: "R 数据文件"),
        DataFormat(id: "parquet", label: "PARQUET", color: Color(hex: 0x8B5CF6), desc: "Parquet 列式"),
        DataFormat(id: "feather", label: "FEATHER", color: Color(hex: 0xEC4899), desc: "Arrow Feather"),
        DataFormat(id: "json",    label: "JSON",    color: Color(hex: 0x65A30D), desc: "JSON 记录"),
    ]

    static func by(id: String) -> DataFormat? { all.first { $0.id == id } }

    static func == (l: DataFormat, r: DataFormat) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
