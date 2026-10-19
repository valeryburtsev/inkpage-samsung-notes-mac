import SwiftUI

/// The colours the palettes of the pens and of the text offer: the Windows client's sets of
/// eight, of which those that are ticked are shown, one row each.
@MainActor @Observable
final class ColorSets {
    static let shared = ColorSets()

    /// The colour sets of the Windows client, eight colours each, in its order; the first four are the ones it shows at first.
    static let all: [[UInt32]] = [
        [0xFFFF_3636, 0xFFFF_CB30, 0xFFF7_EB00, 0xFF2F_EBD2, 0xFF33_96FF, 0xFF14_47FF, 0xFF99_33FF, 0xFF25_2525],
        [0xFFEF_806C, 0xFFD9_4D3C, 0xFF12_3644, 0xFF3F_8881, 0xFF60_88B1, 0xFF50_479A, 0xFFA5_6133, 0xFFCE_B8A1],
        [0xFFFB_E156, 0xFFF0_5268, 0xFF6C_DD8F, 0xFF72_89FF, 0xFFDA_DADA, 0xFF67_6767, 0xFFFF_C000, 0xFF37_D366],
        [0xFF6C_A9E8, 0xFF92_B0E2, 0xFFB0_D29F, 0xFFBA_9500, 0xFFEB_7461, 0xFF74_3AA2, 0xFFC7_67A6, 0xFFC2_7F65],
        [0xFFE9_1E63, 0xFFFF_7043, 0xFFFF_C107, 0xFFCD_DC39, 0xFF00_BCD4, 0xFF2B_61FB, 0xFF79_5548, 0xFF9D_9D9D],
        [0xFFB3_C871, 0xFF9A_D2C9, 0xFFF1_C27D, 0xFFEF_8862, 0xFF6C_69AE, 0xFF8B_7BC9, 0xFFC2_7DC3, 0xFFD2_634E],
        [0xFFF9_DAAE, 0xFFFF_BFA6, 0xFFFE_9A9C, 0xFFFF_85AC, 0xFF68_7AB3, 0xFF87_81AD, 0xFFAE_8EBD, 0xFFD4_88B7],
        [0xFFFF_5E32, 0xFFFF_9002, 0xFFFE_CA93, 0xFFB3_B242, 0xFF54_5691, 0xFF5A_7C7D, 0xFF73_BAC0, 0xFF68_B231],
        [0xFFE9_E9E9, 0xFFD9_D9D9, 0xFFBF_BFBF, 0xFFA6_A6A6, 0xFF91_9191, 0xFF6A_6A6A, 0xFF4E_4E4E, 0xFF04_0400],
        [0xFF91_E2C2, 0xFF04_878F, 0xFFBC_B5E9, 0xFF6F_55B8, 0xFF5C_DEE6, 0xFF69_9BD8, 0xFF00_377A, 0xFF07_1F3C],
        [0xFF43_9AF6, 0xFFA3_F178, 0xFF7A_5DE9, 0xFFD7_559B, 0xFF2E_1EEF, 0xFF7D_FAA7, 0xFFEF_FD6D, 0xFFE8_6536],
        [0xFFE5_4D62, 0xFFFF_8F00, 0xFF24_BCEB, 0xFF78_6AE4, 0xFFFF_DA28, 0xFF8F_D82F, 0xFF01_BC8E, 0xFFEB_5CD9],
        [0xFFFF_0C84, 0xFFFF_2400, 0xFF0D_FB05, 0xFF0D_0DFF, 0xFFFF_00FF, 0xFFFF_FF00, 0xFF00_FFF9, 0xFFA8_2AFF],
        [0xFFFF_D8E2, 0xFFFF_95AE, 0xFFC0_EDFF, 0xFFDD_DFFE, 0xFFFF_FAC3, 0xFFEB_F4C6, 0xFFBD_EFE3, 0xFFF9_DBFC],
        [0xFFFF_7B8B, 0xFFFF_F1CD, 0xFFD6_EA74, 0xFFAF_EAB9, 0xFFFF_B3A3, 0xFFFF_EB62, 0xFFBA_E4E3, 0xFFC1_D2EF],
        [0xFFFB_95D3, 0xFFFF_BBE2, 0xFF9D_97EF, 0xFFA6_8FC4, 0xFFDB_9BF1, 0xFFDB_D5F9, 0xFF78_ACE8, 0xFFEE_EEB0],
        [0xFFBA_0F1B, 0xFFDF_504D, 0xFFFF_DB5E, 0xFFA6_B653, 0xFFE8_7D8D, 0xFFFF_B74F, 0xFFC9_D87B, 0xFF26_998A],
        [0xFFB6_5858, 0xFFDF_A798, 0xFF63_95A0, 0xFFD1_E2E9, 0xFFEA_8F74, 0xFFFF_F4DB, 0xFF7D_C7D2, 0xFF99_94B4],
        [0xFF43_1F0E, 0xFF71_391C, 0xFF37_582D, 0xFF6E_7D46, 0xFF7A_5F4B, 0xFFB0_8E7D, 0xFFC3_C06D, 0xFFC9_D9B2],
        [0xFF91_5D6E, 0xFFC4_A0AE, 0xFFF5_E5E5, 0xFF55_687E, 0xFFBD_7E93, 0xFFF0_CED1, 0xFFAA_BED3, 0xFF3A_4959],
        [0xFF49_4640, 0xFF68_6763, 0xFFBB_B0A2, 0xFFC5_CDCD, 0xFF97_8E8F, 0xFFCE_C4C5, 0xFFD6_D7D2, 0xFFF0_F0F0],
    ]

    /// The sets that are shown, by their places in `all`, in that order.
    var chosen: [Int] {
        didSet { if Launch.value("--editor-check") == nil { UserDefaults.standard.set(chosen, forKey: "colorSets") } }
    }

    private init() {
        let kept = Launch.value("--editor-check") == nil ? UserDefaults.standard.array(forKey: "colorSets") as? [Int] : nil
        chosen = (kept ?? [0, 1, 2, 3]).filter { ColorSets.all.indices.contains($0) }
        if chosen.isEmpty { chosen = [0, 1, 2, 3] }
    }

    /// The colours to show, a row of eight for every set that is ticked.
    var colors: [UInt32] { chosen.sorted().flatMap { ColorSets.all[$0] } }

    func isShown(_ index: Int) -> Bool { chosen.contains(index) }

    /// Ticks a set or unticks it; one set at least stays.
    func toggle(_ index: Int) {
        if chosen.contains(index) { if chosen.count > 1 { chosen.removeAll { $0 == index } } } else { chosen.append(index) }
    }
}

/// The button of the palettes that chooses among the colour sets, and its list.
struct ColorSetsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "circle.grid.3x3.fill").font(.system(size: 10)).symbolRenderingMode(.multicolor)
                .foregroundStyle(.red, .blue, .green)
                .frame(width: Palette.side, height: Palette.side)
                .background(.quaternary.opacity(0.5), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Choose the colour sets to show").accessibilityLabel("Choose the colour sets to show")
        .popover(isPresented: $showing, arrowEdge: .leading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Colour sets").font(.headline).padding(.bottom, 4)
                    ForEach(ColorSets.all.indices, id: \.self) { index in
                        Button { ColorSets.shared.toggle(index) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: ColorSets.shared.isShown(index) ? "checkmark.circle.fill" : "circle").foregroundStyle(ColorSets.shared.isShown(index) ? Color.accentColor : .secondary)
                                ForEach(ColorSets.all[index], id: \.self) { value in
                                    Circle().fill(PenChoice.color(value)).frame(width: 18, height: 18).overlay { Circle().strokeBorder(.primary.opacity(0.1)) }
                                }
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour set \(index + 1)")
                        .accessibilityAddTraits(ColorSets.shared.isShown(index) ? .isSelected : [])
                    }
                }
                .padding(14)
            }
            .frame(width: 250, height: 420)
        }
    }
}
