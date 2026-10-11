import Photos
import SwiftUI
import UIKit

private let bg = Color(red: 0.043, green: 0.071, blue: 0.125)        // #0b1220
private let panel = Color(red: 0.067, green: 0.102, blue: 0.180)     // #111a2e
private let borderColor = Color(red: 0.149, green: 0.220, blue: 0.353)    // #26385a
private let accent = Color(red: 0.133, green: 0.827, blue: 0.933)    // #22d3ee
private let muted = Color(red: 0.557, green: 0.639, blue: 0.769)     // #8ea3c4
private let good = Color(red: 0.290, green: 0.871, blue: 0.502)
private let bad = Color(red: 0.973, green: 0.443, blue: 0.443)

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingName = false
    @State private var nameDraft = ""

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    settingsCard
                    statusCard
                    if !model.canSave { photosCard }
                    statsCard
                    if !model.lastError.isEmpty { errorCard }
                    howTo
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .alert(T("Odebrać pliki?", "Receive files?"),
               isPresented: Binding(get: { model.pendingOffer != nil },
                                    set: { _ in }),          // odpowiedź dają przyciski poniżej
               presenting: model.pendingOffer) { _ in
            Button(T("Odrzuć", "Decline"), role: .cancel) { model.answerOffer(false) }
            Button(T("Akceptuj", "Accept")) { model.answerOffer(true) }
        } message: { offer in
            Text(T("„\(offer.from)” chce wysłać \(offer.files) plików (\(ByteCountFormatter.string(fromByteCount: offer.bytes, countStyle: .file))) \(offer.viaUSB ? "po kablu" : "przez Wi-Fi"). Trafią do galerii.",
                   "“\(offer.from)” wants to send \(offer.files) files (\(ByteCountFormatter.string(fromByteCount: offer.bytes, countStyle: .file))) \(offer.viaUSB ? "over the cable" : "over Wi-Fi"). They will go to the gallery."))
        }
    }

    // MARK: - sekcje

    private var header: some View {
        HStack(spacing: 12) {
            Text("S")
                .font(.system(size: 30, weight: .black))
                .foregroundColor(bg)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(accent))
            VStack(alignment: .leading, spacing: 2) {
                Text("S-TEC Odbiornik").font(.title2.weight(.heavy)).foregroundColor(.white)
                Text(T("Zdjęcia i filmy z komputera prosto do galerii", "Photos and videos from your PC straight to the gallery"))
                    .font(.footnote).foregroundColor(muted)
            }
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Nazwa tego telefonu", "This phone's name")).font(.caption).foregroundColor(muted)
                    Text(model.deviceName).font(.title3.weight(.bold)).foregroundColor(accent)
                }
                Spacer()
                Button(action: { model.randomizeName() }) {
                    Image(systemName: "dice").font(.title3)
                }
                .foregroundColor(muted)
                .padding(.trailing, 8)
                Button(action: { nameDraft = model.deviceName; editingName = true }) {
                    Image(systemName: "pencil").font(.title3)
                }
                .foregroundColor(muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(T("Odbieraj przez", "Receive via")).font(.caption).foregroundColor(muted)
                Picker("", selection: $model.mode) {
                    Text(T("Kabel", "Cable")).tag(ReceiveMode.cable)
                    Text("Wi-Fi").tag(ReceiveMode.wifi)
                    Text(T("Kabel + Wi-Fi", "Cable + Wi-Fi")).tag(ReceiveMode.both)
                }
                .pickerStyle(.segmented)
            }
            Toggle(isOn: $model.askBeforeReceive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Pytaj przed odbiorem", "Ask before receiving")).font(.subheadline).foregroundColor(.white)
                    Text(T("Pokaże „Akceptuj / Odrzuć”, gdy komputer chce coś wysłać.",
                           "Shows “Accept / Decline” when a computer wants to send something."))
                        .font(.caption).foregroundColor(muted)
                }
            }
            .tint(accent)
        }
        .padding(16)
        .background(card)
        .alert(T("Nazwa telefonu", "Phone name"), isPresented: $editingName) {
            TextField(T("np. Rudy Lis", "e.g. Red Fox"), text: $nameDraft)
            Button(T("Anuluj", "Cancel"), role: .cancel) {}
            Button(T("Zapisz", "Save")) {
                let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.deviceName = String(trimmed.prefix(40)) }
            }
        } message: {
            Text(T("Tak telefon będzie widoczny w programie S-TEC na komputerze.",
                   "This is how the phone appears in S-TEC on the computer."))
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 12, height: 12)
                Text(statusTitle).font(.headline).foregroundColor(.white)
            }
            Text(statusDetail).font(.subheadline).foregroundColor(muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.phase == .receiving && !model.currentFile.isEmpty {
                Text(model.currentFile).font(.caption.monospaced()).foregroundColor(accent).lineLimit(1)
            }
            if let ip = model.wifiAddress, model.mode.allowsWifi {
                HStack {
                    Text(T("Adres do trybu Wi-Fi:", "Address for Wi-Fi mode:")).font(.caption).foregroundColor(muted)
                    Text(ip).font(.caption.monospaced().weight(.semibold)).foregroundColor(.white)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(card)
    }

    private var statsCard: some View {
        VStack(spacing: 12) {
            HStack {
                stat(T("Odebrane", "Received"), "\(model.received)")
                stat(T("W galerii", "In gallery"), "\(model.saved)", good)
                stat(T("Błędy", "Errors"), "\(model.failed)", model.failed > 0 ? bad : .white)
            }
            HStack {
                stat(T("Dane", "Data"), ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                stat(T("Prędkość", "Speed"), model.speed > 0 ? String(format: "%.1f MB/s", model.speed / 1_000_000) : "–", accent)
                Button(action: { model.resetCounters() }) {
                    Text(T("Wyzeruj", "Reset")).font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().stroke(borderColor))
                }
                .foregroundColor(muted)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(card)
    }

    private var photosCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Brak dostępu do Zdjęć", "No access to Photos")).font(.headline).foregroundColor(bad)
            Text(T("Bez tego pliki nie trafią do galerii. Zezwól na pełny dostęp.",
                   "Without it files cannot be saved to the gallery. Allow full access."))
                .font(.subheadline).foregroundColor(muted)
            Button(action: openPhotosPermission) {
                Text(model.photoStatus == .notDetermined ? T("Zezwól", "Allow") : T("Otwórz Ustawienia", "Open Settings"))
                    .font(.subheadline.weight(.semibold)).foregroundColor(bg)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(accent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(card)
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(T("Ostatni błąd", "Last error")).font(.caption.weight(.semibold)).foregroundColor(bad)
            Text(model.lastError).font(.caption).foregroundColor(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(card)
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(T("Jak wysłać", "How to send")).font(.footnote.weight(.semibold)).foregroundColor(.white)
            Group {
                Text(T("1. Kabel: podłącz iPhone'a i odblokuj go („Zaufaj temu komputerowi”). Wi-Fi: ta sama sieć co komputer.",
                       "1. Cable: connect and unlock the iPhone (“Trust This Computer”). Wi-Fi: same network as the PC."))
                Text(T("2. W S-TEC (zakładka „Wyślij na iPhone”) wybierz ten telefon z listy i kliknij „Wyślij”.",
                       "2. In S-TEC (“Send to iPhone” tab) choose this phone from the list and click “Send”."))
                Text(T("3. Nie zamykaj tej aplikacji i nie blokuj ekranu, aż skończy – ekran sam nie zgaśnie.",
                       "3. Keep this app open and do not lock the phone until it finishes – the screen stays on."))
            }
            .font(.footnote).foregroundColor(muted)
            .fixedSize(horizontal: false, vertical: true)
            Text("Tom Stec & Uncle Claude").font(.caption2).foregroundColor(muted.opacity(0.6)).padding(.top, 6)
        }
    }

    // MARK: - pomocnicze

    private var card: some View {
        RoundedRectangle(cornerRadius: 16).fill(panel)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1))
    }

    private func stat(_ title: String, _ value: String, _ color: Color = .white) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold).monospacedDigit()).foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundColor(muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusColor: Color {
        switch model.phase {
        case .receiving: return accent
        case .finished: return good
        case .error: return bad
        default: return muted
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .starting: return T("Uruchamiam…", "Starting…")
        case .waiting: return T("Gotowy do odbioru", "Ready to receive")
        case .receiving:
            return model.viaUSB ? T("Odbieram po kablu", "Receiving over cable") : T("Odbieram przez Wi-Fi", "Receiving over Wi-Fi")
        case .finished: return T("Zakończono", "Finished")
        case .error: return T("Błąd nasłuchu", "Listening error")
        }
    }

    private var statusDetail: String {
        switch model.phase {
        case .waiting, .starting:
            switch model.mode {
            case .cable:
                return T("Podłącz kabel – telefon „\(model.deviceName)” pojawi się w S-TEC (zakładka „Wyślij na iPhone”).",
                         "Connect the cable – “\(model.deviceName)” will appear in S-TEC (“Send to iPhone” tab).")
            case .wifi:
                return T("Telefon „\(model.deviceName)” jest widoczny w sieci Wi-Fi – wybierz go w S-TEC na komputerze.",
                         "“\(model.deviceName)” is visible on Wi-Fi – choose it in S-TEC on the computer.")
            case .both:
                return T("Telefon „\(model.deviceName)” czeka na pliki – po kablu albo przez Wi-Fi. Wybierz go w S-TEC.",
                         "“\(model.deviceName)” is waiting for files – via cable or Wi-Fi. Choose it in S-TEC.")
            }
        case .receiving:
            return T("Od: \(model.peerName). Nie zamykaj aplikacji i nie blokuj ekranu.",
                     "From: \(model.peerName). Keep the app open and the screen unlocked.")
        case .finished:
            return T("Zapisano w galerii: \(model.saved). Możesz wysłać kolejne pliki.",
                     "Saved to the gallery: \(model.saved). You can send more files.")
        case .error:
            return model.listenerError
        }
    }

    private func openPhotosPermission() {
        if model.photoStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { model.photoStatus = status }
            }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
