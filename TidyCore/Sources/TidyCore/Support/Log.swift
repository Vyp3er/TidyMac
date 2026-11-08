import os

public enum Log {
    public static let scan = Logger(subsystem: "de.tidymac.core", category: "scan")
    public static let plan = Logger(subsystem: "de.tidymac.core", category: "plan")
    public static let exec = Logger(subsystem: "de.tidymac.core", category: "execute")
    public static let ai = Logger(subsystem: "de.tidymac.core", category: "ai")
    public static let background = Logger(subsystem: "de.tidymac.core", category: "background")
}
