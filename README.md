# OnAir – 1 etapas (prototipas)

Asmeninė radijo stotis su DJ, grojanti iš tavo Spotify. Šis etapas tikrina svarbiausią ir rizikingiausią dalį:

- prisijungimą prie Spotify;
- grojimą tavo telefono Spotify programėlėje;
- DJ balsą, kai Spotify patylinamas, o ne sustabdomas;
- ar viskas veikia užrakintu ekranu.

Dainos šiame etape imamos tik iš tavo Spotify „Top“ sąrašų. Naujų dainų atradimas (Last.fm), patinka/nepatinka, atlikėjų faktai ir klausymo statistika ateis 2–3 etapuose.

---

## Ko reikia

- Mac (M1 Air tinka) su naujausia macOS versija
- **Xcode** (nemokamai iš Mac App Store, apie 10 GB)
- iPhone ir laidas jam prijungti prie Mac
- Spotify Premium ir Spotify programėlė iPhone

Užtruks maždaug 30–40 min. Didžiąją dalį laiko užima Xcode atsisiuntimas.

---

## 1. Susikurk Spotify Developer programėlę (5 min)

1. Atidaryk <https://developer.spotify.com/dashboard> ir prisijunk savo Spotify paskyra.
2. Jei prašo, sutik su sąlygomis.
3. Spausk **Create app** ir užpildyk:
   - **App name:** `OnAir`
   - **App description:** `Personal radio`
   - **Redirect URIs:** įrašyk `onairfm://callback` ir spausk **Add**. Svarbu: be tarpų, mažosiomis raidėmis.
   - **Which API/SDKs are you planning to use:** pažymėk **Web API**
   - Pažymėk sutikimą ir spausk **Save**.
4. Atsidariusiame lange spausk **Settings** ir nusikopijuok **Client ID**.
5. Ten pat atidaryk skirtuką **User Management** ir pridėk save: vardą ir el. paštą, kuriuo prisijungi prie Spotify. Tai apsaugo nuo galimos 403 klaidos.

## 2. Įrašyk Client ID

Atidaryk failą `OnAir/App/Config.swift` ir pakeisk šią eilutę:

```swift
static let spotifyClientID = "PASTE_YOUR_SPOTIFY_CLIENT_ID_HERE"
```

Kabutėse turi būti tavo Client ID.

## 3. Pakeisk programėlės ID

Atidaryk `project.yml` ir pakeisk `lt.CHANGEME.onair` į ką nors unikalaus, pvz. `lt.tavovardas.onair`. Naudok tik mažąsias lotyniškas raides, be tarpų ir be lietuviškų raidžių.

## 4. Sugeneruok Xcode projektą

Atidaryk **Terminal** programą Mac'e.

Įdiek Homebrew (jei dar neturi):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Diegimo pabaigoje Homebrew parodys 2 komandas skiltyje „Next steps“. Nukopijuok ir paleisk jas.

Įdiek XcodeGen ir sugeneruok projektą:

```bash
brew install xcodegen
cd ~/Downloads/OnAir
xcodegen
open OnAir.xcodeproj
```

Jei aplanką išskleidei kitur, `cd` eilutėje pakeisk kelią. Lengviausia parašyti `cd `, tada į Terminal langą nutempti `OnAir` aplanką ir paspausti Enter.

## 5. Nustatyk pasirašymą Xcode (nemokamai)

1. Xcode meniu pasirink **Xcode → Settings → Accounts**, spausk **+** ir pridėk savo Apple ID.
2. Kairėje spausk mėlyną **OnAir** projektą, tada **Targets → OnAir → Signing & Capabilities**.
3. Lauke **Team** pasirink `Tavo Vardas (Personal Team)`.
4. Jei matai raudoną klaidą apie bundle identifier, grįžk į 3 žingsnį, sugalvok kitą ID ir paleisk `xcodegen` dar kartą.

## 6. Įdiek į iPhone

1. Prijunk iPhone laidu. Telefone paspausk **Pasitikėti** (Trust).
2. iPhone įjunk **Nustatymai → Privatumas ir sauga → Kūrėjo režimas** (Developer Mode). Telefonas persikraus.
3. Xcode viršuje, šalia ▶ mygtuko, pasirink savo iPhone.
4. Spausk **▶** (arba ⌘R).
5. Pirmą kartą iPhone parodys, kad kūrėjas nepatikimas. Eik į **Nustatymai → Bendrieji → VPN ir įrenginių valdymas**, pasirink savo Apple ID ir spausk **Pasitikėti**. Tada Xcode vėl spausk ▶.

**Svarbu:** su nemokama paskyra programėlė veikia 7 dienas. Po to prijunk telefoną ir Xcode vėl spausk ▶.

## 7. Paleisk stotį

1. Atidaryk **Spotify** programėlę telefone. Paleisti nieko nereikia, užtenka atidaryti.
2. Atidaryk **OnAir** ir spausk **Prisijungti su Spotify**.
3. Skirtuke **Stotis** spausk **Įjungti stotį**.

Rekomenduoju: nustatymuose atsisiųsk geresnį anglų balsą. Kelias: iPhone **Nustatymai → Pritaikymas neįgaliesiems → Įgarsinamas turinys → Balsai → English**, rinkis „Enhanced“ arba „Premium“ balsą (pvz. „Ava (Premium)“). Tada OnAir nustatymuose pasirink jį arba palik „Automatiškai“.

---

## Ką patikrinti (ir parašyti man)

| # | Testas | Ko tikimės |
|---|---|---|
| 1 | Prisijungimas | Atsidaro Spotify puslapis, sutinki, grįžti į programėlę |
| 2 | Įjungti stotį | Spotify pradeda groti, OnAir rodo dainą ir eilę su laikais |
| 3 | Atidarymas | Muzika patyla, DJ pasisveikina ir pristato dainą, muzika vėl garsėja |
| 4 | Po 3 dainų | DJ pasako, kas grojo, ir pristato kitą dainą |
| 5 | **Užrakintas ekranas** | Užrakink telefoną 15+ min. DJ vis tiek turi kalbėti kas 3 dainas |
| 6 | Ausinės / Bluetooth | Patylinimas veikia ir per jas |
| 7 | „DJ dabar“ mygtukas | DJ iškart prabyla ant dainos |

Jei kažkas neveikia:

1. Atidaryk skirtuką **Žurnalas**.
2. Spausk **Dalintis**.
3. Atsiųsk man tekstą ir parašyk, kurio testo numeris nepavyko.

Jei 3 testas neveikia (Spotify nepatyla, o DJ kalba per garsiai arba jo negirdėti), nustatymuose pabandyk „Kai DJ kalba → Sustabdyti muziką“ ir parašyk, ar taip veikia.

---

## Projekto struktūra

```
OnAir/
├─ project.yml              XcodeGen projekto aprašas
└─ OnAir/
   ├─ App/                  Programėlės pradžia, Config (Client ID)
   ├─ Spotify/              Prisijungimas (PKCE), Web API klientas, modeliai
   ├─ Audio/                Fono palaikymas, Spotify patylinimas, DJ balsas
   ├─ Station/              Stoties variklis, dainų parinkimas, DJ tekstai
   ├─ UI/                   Ekranai
   └─ Support/              Žurnalas, Keychain
```

## Kaip tai veikia

- **Muziką groja Spotify programėlė.** OnAir per Spotify Web API jai nusiunčia dainų sąrašą ir seka, kas groja. Būsena tikrinama kas ~15 s, o artėjant dainos pabaigai – tiksliai jos pabaigoje.
- **DJ balsas** yra nemokamas Apple sistemos balsas. Kol jis kalba, OnAir įjungia iOS „ducking“ režimą: Spotify garsas sumažėja, bet daina negroja iš naujo ir nesustoja.
- **Kad veiktų užrakintu ekranu,** OnAir fone groja tylą. Kitaip iOS programėlę užmigdytų.
- **Kiekvienos stoties pradžioje** OnAir paima tavo „Top“ dainas (4 sav., 6 mėn., visų laikų). Vengia dainų, kurias neseniai klausei, o to paties atlikėjo nededa dviejų iš eilės. Kai sąrašas baigiasi, į Spotify eilę automatiškai prideda dar 6 dainas.
