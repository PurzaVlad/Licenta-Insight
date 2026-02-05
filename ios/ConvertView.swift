import SwiftUI

struct ConvertView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        ConvertSectionHeader(title: "From PDF")
                        ConvertRow(title: "PDF to DOCX", icon: .pdfToDocx) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.docx,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.pdf]
                            )
                                .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PDF to PPTX", icon: .pdfToPptx) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.pptx,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.pdf]
                            )
                                .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PDF to XLSX", icon: .pdfToXlsx) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.xlsx,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.pdf]
                            )
                                .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PDF to JPG", icon: .pdfToJpg) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.image,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.pdf]
                            )
                                .environmentObject(documentManager)
                        }

                        ConvertSectionHeader(title: "To PDF")
                        ConvertRow(title: "DOCX to PDF", icon: .docxToPdf) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.pdf,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.docx]
                            )
                                .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PPTX to PDF", icon: .pptxToPdf) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.pdf,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.pptx]
                            )
                                .environmentObject(documentManager)
                        }
                        ConvertRow(title: "XLSX to PDF", icon: .xlsxToPdf) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.pdf,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.xlsx]
                            )
                                .environmentObject(documentManager)
                        }
                        ConvertRow(title: "JPG to PDF", icon: .jpgToPdf) {
                            ConversionView(
                                initialTargetFormat: ConversionView.DocumentFormat.pdf,
                                autoPresentPicker: true,
                                showsNavigation: false,
                                allowedSourceTypes: [.image]
                            )
                                .environmentObject(documentManager)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .padding(.horizontal, 16)

                    Spacer()
                }
                .padding(.top, 8)
            }
            .hideScrollBackground()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
}

struct ConvertRow<Destination: View>: View {
    let title: String
    let icon: ConvertIconType
    let destination: Destination

    init(title: String, icon: ConvertIconType, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.icon = icon
        self.destination = destination()
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                ConvertIcon(type: icon)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color("Primary"))
            }
            .padding(.vertical, 6)
        }
        Divider()
    }
}

enum ConvertIconType {
    case pdfToDocx
    case pdfToPptx
    case pdfToXlsx
    case pdfToJpg
    case docxToPdf
    case pptxToPdf
    case xlsxToPdf
    case jpgToPdf
}

struct ConvertIcon: View {
    let type: ConvertIconType

    var body: some View {
        switch type {
        case .pdfToDocx:
            pdfToDocxIcon
        case .pdfToPptx:
            pdfToPptxIcon
        case .pdfToXlsx:
            pdfToXlsxIcon
        case .pdfToJpg:
            pdfToJpgIcon
        case .docxToPdf:
            docxToPdfIcon
        case .pptxToPdf:
            pptxToPdfIcon
        case .xlsxToPdf:
            xlsxToPdfIcon
        case .jpgToPdf:
            jpgToPdfIcon
        }
    }

    private var pdfToDocxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 8, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToPptxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToXlsxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "tablecells")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToJpgIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var docxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "doc.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pptxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var xlsxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 20, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "tablecells.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var jpgToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 20, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "photo.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
}

struct ConvertSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

#Preview {
  ConvertView()
}
