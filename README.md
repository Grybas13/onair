# OnAir

Asmeninė radijo stotis su DJ, grojanti iš tavo Spotify (Rad.FM idėja, tik Spotify'ui).

**1 etapas (prototipas)** tikrina svarbiausią dalį:

- prisijungimą prie Spotify;
- grojimą tavo telefono Spotify programėlėje;
- DJ balsą, kai Spotify patylinamas, o ne sustabdomas;
- ar viskas veikia užrakintu ekranu.

Dainos šiame etape imamos iš tavo Spotify „Top“ sąrašų. Naujų dainų atradimas, patinka/nepatinka, atlikėjų faktai ir klausymo statistika ateis vėlesniuose etapuose.

Programėlė kompiliuojama GitHub serveriuose, todėl **Mac nereikia**. Įdiegiama iš Windows per Sideloadly.

---

## 1. Spotify Developer programėlė (vieną kartą, 5 min)

1. Atidaryk <https://developer.spotify.com/dashboard> ir prisijunk savo Spotify paskyra.
2. Spausk **Create app** ir užpildyk:
   - **App name:** `OnAir`
   - **App description:** `Personal radio`
   - **Redirect URIs:** įrašyk `onairfm://callback` ir spausk **Add**
   - **Which API/SDKs:** pažymėk **Web API**
   - Pažymėk sutikimą ir spausk **Save**.
3. Spausk **Settings** ir nusikopijuok **Client ID**.
4. Ten pat skirtuke **User Management** pridėk save: vardą ir Spotify el. paštą.

## 2. Client ID į GitHub (vieną kartą)

1. Šioje repozitorijoje eik **Settings → Secrets and variables → Actions → New repository secret**.
2. Užpildyk:
   - **Name:** `SPOTIFY_CLIENT_ID`
   - **Secret:** tavo Client ID
3. Spausk **Add secret**.

Tada paleisk kompiliavimą iš naujo: **Actions → Build IPA → Run workflow → Run workflow**.

## 3. Atsisiųsk .ipa

1. **Actions** skirtuke atidaryk naujausią žalią ✅ „Build IPA“ įrašą.
2. Apačioje, skiltyje **Artifacts**, spausk **OnAir-ipa**.
3. Atsisiųsi `.zip` failą. Išskleidus jame bus `OnAir.ipa`.

## 4. Įdiek per Sideloadly (Windows)

Vieną kartą paruošk kompiuterį:

1. Įdiek **iTunes** ir **iCloud** iš Apple svetainės, **ne** iš Microsoft Store. Jei turi Microsoft Store versijas, pirma jas pašalink.
2. Įdiek [Sideloadly](https://sideloadly.io/).

Diegimas:

1. Prijunk iPhone laidu ir telefone paspausk **Pasitikėti**.
2. Sideloadly lange:
   - nutempk `OnAir.ipa` į langą;
   - įrašyk savo Apple ID el. paštą;
   - spausk **Start**;
   - įvesk Apple ID slaptažodį, kai paprašys (jį mato tik Sideloadly ir Apple).
3. iPhone:
   - **Nustatymai → Bendrieji → VPN ir įrenginių valdymas** → pasirink savo Apple ID → **Pasitikėti**.
   - **Nustatymai → Privatumas ir sauga → Kūrėjo režimas (Developer Mode)** → įjunk. Telefonas persikraus.

**Kas 7 dienas** nemokamas parašas baigiasi. Tada vėl įdiek per Sideloadly. Jei Sideloadly įjungsi automatinį atnaujinimą (rodyklių ikonėlė šalia Start) ir paliksi jį veikti tame pačiame Wi-Fi, atnaujins pats.

Kai išeis nauja versija, tiesiog atsisiųsk naują .ipa ir įdiek tuo pačiu būdu. Nustatymai ir prisijungimas išliks.

## 5. Paleisk stotį

1. Atidaryk **Spotify** programėlę telefone. Užtenka atidaryti, nieko groti nereikia.
2. Atidaryk **OnAir** ir spausk **Prisijungti su Spotify**.
3. Skirtuke **Stotis** spausk **Įjungti stotį**.

Rekomenduoju atsisiųsti geresnį anglų balsą: iPhone **Nustatymai → Pritaikymas neįgaliesiems → Įgarsinamas turinys → Balsai → English**, rinkis „Enhanced“ arba „Premium“ balsą (pvz. „Ava (Premium)“).

---

## Ką patikrinti

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
3. Atsiųsk tekstą ir parašyk, kurio testo numeris nepavyko.

Jei 3 testas neveikia, nustatymuose pabandyk „Kai DJ kalba → Sustabdyti muziką“.

---

## Kaip tai veikia

- **Muziką groja Spotify programėlė.** OnAir per Spotify Web API jai nusiunčia dainų sąrašą ir seka, kas groja. Būsena tikrinama kas ~15 s, o artėjant dainos pabaigai – tiksliai jos pabaigoje.
- **DJ balsas** yra nemokamas Apple sistemos balsas. Kol jis kalba, iOS sumažina Spotify garsą („ducking“).
- **Kad veiktų užrakintu ekranu,** OnAir fone groja tylą. Kitaip iOS programėlę užmigdytų.
- **Grojaraštis „OnAir Radio“.** Spotify iPhone programėlė nuo 2026 rudens nebepaleidžia per API atsiųstų „plikų“ dainų sąrašų, tik grojaraščius ar albumus. Todėl OnAir tavo bibliotekoje laiko privatų grojaraštį „OnAir Radio“ ir prieš kiekvieną eterį jį perrašo. Jo netrinkite – o jei ištrinsite, OnAir sukurs naują.
- **Jei Spotify telefone miega,** OnAir trumpam atidaro Spotify programėlę, kad ji pabustų, ir tada paleidžia stotį.
- **Dainų parinkimas.** OnAir paima tavo „Top“ dainas (4 sav., 6 mėn., visų laikų). Vengia dainų, kurias neseniai klausei, o to paties atlikėjo nededa dviejų iš eilės. Kai iki sąrašo pabaigos lieka 3 dainos, į grojaraštį prideda dar 6.

## Projekto struktūra

```
.github/workflows/build.yml   Kompiliavimas GitHub'e → OnAir.ipa
project.yml                   XcodeGen projekto aprašas
OnAir/
├─ App/        Programėlės pradžia, Config
├─ Spotify/    Prisijungimas (PKCE), Web API klientas, modeliai
├─ Audio/      Fono palaikymas, Spotify patylinimas, DJ balsas
├─ Station/    Stoties variklis, dainų parinkimas, DJ tekstai
├─ UI/         Ekranai
└─ Support/    Žurnalas, Keychain
```
