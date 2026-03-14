# WeatherRelay / WeatherComputer
## User Manual

### Document Purpose
This manual provides operating instructions for the WeatherRelay iPhone application and its associated WeatherComputer device as implemented in this repository. It is written for a technical end user or field operator. It describes how to operate the system, what to expect during normal use, and what limitations apply to the current implementation.

This manual does not describe software development procedures.

## 1. SYSTEM OVERVIEW

### 1.1 General Description
The system consists of an iPhone application named `WeatherRelay` and a Bluetooth Low Energy (BLE) device named `WeatherComputer`.

The iPhone application performs the following functions:

1. Acquires the iPhone's current geographic position using Core Location.
2. Connects to the WeatherComputer over BLE.
3. Retrieves NOAA gridded forecast data for a 3 x 3 weather field centered on the current location.
4. Derives three forecast time slots for each field anchor.
5. Builds compact protocol packets for position and regional weather.
6. Sends those packets to the WeatherComputer over BLE.
7. Displays weather field data on an embedded Apple Maps page for engineering and diagnostic use.

In plain operational terms, the data path is:

`iPhone -> GPS -> NOAA -> 3 x 3 weather field -> BLE -> WeatherComputer`

### 1.2 System Purpose
The system provides the WeatherComputer with two primary classes of information:

1. Current position of the phone.
2. A compact regional weather snapshot describing forecast conditions over a surrounding area.

The WeatherComputer then stores that information and uses it for onboard estimation, persistence, and display behavior.

### 1.3 Purpose of the Regional Weather Field
The regional weather field represents forecast conditions not just at one point, but across an area surrounding the field center. This allows the device to reason about nearby conditions instead of relying on a single forecast point.

The implemented weather field uses nine anchor points arranged in a 3 x 3 grid:

- `r0c0`, `r0c1`, `r0c2`
- `r1c0`, `r1c1`, `r1c2`
- `r2c0`, `r2c1`, `r2c2`

The center anchor is `r1c1`.

### 1.4 Why a 3 x 3 Grid Is Used
The 3 x 3 grid provides spatial coverage around the field center while keeping the packet compact enough for BLE transport and embedded-device storage.

As implemented:

- field width: 240 miles
- field height: 240 miles
- anchor spacing: 120 miles from center to adjacent anchor

This produces a coarse regional picture that can reflect changes across the area rather than only at the phone's exact location.

### 1.5 Forecast Time Horizon
Each anchor contains three forecast slots:

- slot `0 min`: conditions for `[T0, T0 + 60 minutes)`
- slot `60 min`: conditions for `[T0 + 60 minutes, T0 + 120 minutes)`
- slot `120 min`: conditions for `[T0 + 120 minutes, T0 + 180 minutes)`

`T0` is one shared field anchor time established when the 3 x 3 fetch batch begins. All nine anchors use the same `T0`.

Accordingly, the field represents an approximately three-hour forecast horizon, expressed as three one-hour windows.

## 2. SYSTEM COMPONENTS

### 2.1 iPhone Application
The iPhone app is the active control and data-acquisition component. Its responsibilities include:

- acquiring live GPS position from the phone
- requesting and maintaining BLE connectivity with the WeatherComputer
- requesting NOAA forecast grid data
- synthesizing the 3 x 3 weather field
- converting weather data into the `RegionalSnapshotV1` packet format
- converting live position into the `PositionUpdateV1` packet format
- sending packets to the WeatherComputer over BLE
- receiving and decoding `AckV1` acknowledgements from the WeatherComputer
- displaying diagnostic weather data and a map-based field visualization

The app contains three main operator-visible pages:

1. Main status page
2. `Weather Debug` page
3. `Weather Field Map` page

### 2.2 WeatherComputer
The WeatherComputer is the BLE peripheral targeted by the app. The app expects it to advertise the peripheral name:

`WeatherComputer`

The firmware-side protocol visible from the app indicates that the WeatherComputer:

- accepts BLE writes on an RX characteristic
- transmits acknowledgements on a TX notify characteristic
- validates packet format and CRC
- stores accepted position updates
- stores accepted regional weather snapshots
- reports success or failure by sending an `AckV1`

The WeatherComputer is therefore the onboard receiving, storage, and runtime consumer of the transmitted data.

### 2.3 NOAA Weather Service
The app uses NOAA as the canonical weather source. For each anchor coordinate, the app performs:

1. `/points/{lat},{lon}`
2. use the returned `forecastGridData` URL
3. fetch `forecastGridData`

The app does not use nearest-node snapping as the primary field representation. NOAA itself resolves each exact anchor coordinate to the appropriate forecast office and grid.

### 2.4 Apple Maps Visualization
The `Weather Field Map` page uses Apple MapKit. It displays:

- the field center
- all nine anchors
- an approximate 240-mile field boundary
- compact per-anchor annotations for the selected forecast slot

This page is a debug/engineering display rather than a polished end-user dashboard.

## 3. INSTALLATION AND SETUP

### 3.1 iPhone Requirements
Based on current project settings, the app target is configured for:

- iPhone deployment target: iOS 26.2

Operationally, the phone must have:

- Bluetooth enabled
- Location Services enabled
- internet connectivity for NOAA weather retrieval

The app requests or uses these permissions:

- Bluetooth access
- Location When In Use
- Location Always and When In Use

The app is also configured with iPhone background modes for:

- `location`
- `bluetooth-central`

These settings provide scaffolding for background operation, though they do not by themselves guarantee continuous background execution.

### 3.2 WeatherComputer Preparation
Before using the system:

1. Power the WeatherComputer.
2. Confirm that the firmware is advertising over BLE.
3. Confirm that the BLE peripheral name is `WeatherComputer`.
4. Place the phone within normal BLE range of the WeatherComputer.

If the WeatherComputer is not advertising, the app cannot connect.

### 3.3 First Launch Procedure
Perform the following:

1. Install and open the `WeatherRelay` app on the iPhone.
2. When prompted, grant Bluetooth access.
3. When prompted, grant location access.
4. Wait for the app to acquire an initial position fix.
5. Observe the main status page until the BLE status progresses to `Ready`.

If the app presents `Enable Background Location`, select it only if you intend to allow Always authorization for extended or background-capable operation.

## 4. NORMAL OPERATING PROCEDURE

### 4.1 Launching the Application
Use the following procedure:

1. Open the app.
2. Observe the main page status line.
3. Confirm that Bluetooth is powered on.
4. Confirm that location status progresses to `Location ready`.
5. Confirm that the app begins scanning for the WeatherComputer.

The main page displays:

- scan state
- last discovered peripheral name
- last advertised name
- whether the target was found
- latest ACK summary
- latest location status and coordinates

### 4.2 Establishing BLE Connection
The app discovers the WeatherComputer by broad BLE scanning and matches on either:

- the peripheral name `WeatherComputer`
- or the advertised local name `WeatherComputer`

After the target is found, the app:

1. connects automatically
2. discovers services
3. discovers characteristics
4. enables notifications on the TX characteristic

When discovery is complete, the status changes to `Ready`.

### 4.3 Automatic Reconnection Behavior
If the connection drops, the app automatically returns to scanning and reconnect logic. The app also contains BLE state restoration logic:

- restored peripherals are stored first
- BLE work resumes only after the central reports `poweredOn`
- if a peripheral was restored as already connected, service discovery resumes after `poweredOn`

This means the system is designed to recover from normal disconnects and from some iOS restoration cases without user intervention.

### 4.4 Position Acquisition
The app continuously receives location updates from the iPhone once authorized. A valid position fix must exist before position transmission can occur.

The app treats a fix as unsuitable for the automatic send check if:

- no fix exists
- horizontal accuracy is invalid
- the fix is stale

The current implementation uses a freshness threshold of approximately 60 seconds for automatic send consideration.

### 4.5 Weather Field Acquisition
Weather retrieval currently occurs when the user enters the `Weather Debug` page and selects:

`Fetch NOAA 3x3 Field`

The app then:

1. uses the current phone location as the field center
2. generates nine anchor coordinates at the fixed Block 1 geometry
3. fetches NOAA `/points` for each anchor independently
4. follows each anchor's `forecastGridData` URL
5. derives a three-slot forecast model for each anchor
6. builds a packet-ready regional weather snapshot

Important current behavior:

- weather fetching is implemented and working
- weather transmission is integrated into the normal send cycle
- however, a newer weather field must first exist in the app
- today, that newer weather field is created by the `Fetch NOAA 3x3 Field` action on the debug page

Accordingly, the normal send path can send weather automatically only after a fresh weather field has been fetched and built.

### 4.6 How the 3 x 3 Grid Is Built
The app computes the nine anchors relative to the center fix using the frozen Block 1 geometry:

- center anchor: `r1c1`
- adjacent anchor spacing: 120 miles
- overall field size: 240 miles by 240 miles

Anchors are ordered row-major:

1. `r0c0`
2. `r0c1`
3. `r0c2`
4. `r1c0`
5. `r1c1`
6. `r1c2`
7. `r2c0`
8. `r2c1`
9. `r2c2`

Each anchor is processed independently through NOAA.

### 4.7 Weather Transmission
The app maintains a normal position send cadence of approximately 10 minutes. The source of truth is the time of the last successfully accepted position send.

On a relevant event, the app evaluates whether a send is due. Relevant events include:

- BLE becomes ready
- a new location fix arrives
- the app becomes active
- a reconnect occurs

If a send is due:

- if newer weather exists since the last accepted weather send, the app sends `RegionalSnapshotV1` first, then `PositionUpdateV1`
- if no newer weather exists, the app sends only `PositionUpdateV1`

The app does not branch on a separate "internet available" operating mode. Position cadence continues on schedule. Weather is included when newer weather has already been fetched and built.

### 4.8 Required Conditions for Normal Send
For the normal send check to succeed, the following must be true:

1. BLE must be connected and ready.
2. A valid live location fix must exist.
3. The fix must be fresh enough.
4. No earlier position send may be awaiting ACK.
5. No weather chunk transfer may already be in progress.

### 4.9 Manual Debug Sends
Two manual debug actions are provided on the `Weather Debug` page:

- `Send PositionUpdateV1`
- `Send RegionalSnapshotV1`

These are intended for engineering verification and override testing.

The weather packet send is allowed only if the built packet length is exactly 470 bytes.

## 5. MAP DISPLAY OPERATION

### 5.1 Purpose of the Map Page
The `Weather Field Map` page provides a spatial view of the current 3 x 3 weather field. It is intended as a diagnostic aid.

### 5.2 Accessing the Map
From the main page:

1. Select `Weather Field Map`.
2. If no field has yet been fetched, the page will state that no weather field is available.
3. Fetch a 3 x 3 field from `Weather Debug` first if needed.

### 5.3 Map Centering
The map centers on the current field center coordinate. The camera span is expanded enough to include:

- all nine anchors
- the full field rectangle

### 5.4 Grid and Boundary Display
The map shows:

- the nine anchor points as custom annotations
- an approximate rectangular boundary representing the 240-mile by 240-mile field

The boundary is a planning and debug aid. It is an approximate geometric box around the selected field center.

### 5.5 Annotation Content
Each anchor annotation shows:

- anchor identifier, for example `r1c2`
- wind as `Wxx` in miles per hour
- visibility as `Vxx` in miles

These are display-layer units only. Internal weather calculations and packet construction remain in metric units.

### 5.6 Slot Selection
The map page provides a segmented selector:

- `0 min`
- `60 min`
- `120 min`

Selecting a slot updates the displayed annotation values so the map reflects that specific one-hour forecast window.

### 5.7 Missing Data Indication
Anchors with missing NOAA data are visually distinguished from valid anchors:

- valid anchors: blue
- missing anchors: gray

Missing anchors may occur when an anchor coordinate falls outside supported NOAA coverage for the selected location.

## 6. DATA MODEL DESCRIPTION

### 6.1 General Packet Types
The app uses these protocol packet types:

- `weatherSnapshot` = packet type 1
- `positionUpdate` = packet type 2
- `ack` = packet type 3

### 6.2 PositionUpdateV1
`PositionUpdateV1` contains:

- current latitude
- current longitude
- position accuracy
- fix timestamp

It is a compact 32-byte packet sent over BLE.

### 6.3 RegionalSnapshotV1
`RegionalSnapshotV1` is the weather packet sent to the WeatherComputer. It is exactly 470 bytes long and contains:

1. a common packet header
2. top-level field metadata
3. 27 weather cells

The 27 cells represent:

- 9 anchors
- 3 time slots per anchor

### 6.4 Field Structure in User Terms
The packet describes:

- a 3 x 3 grid centered on the field center
- a 240-mile by 240-mile field
- three forecast slots at 0, 60, and 120 minutes

### 6.5 Variables Included
Each anchor/slot cell includes these weather variables:

- temperature
- wind speed
- wind gust
- precipitation probability
- precipitation kind
- precipitation intensity
- visibility
- hazard flags

### 6.6 Units
Operator-facing units and packet units are not always the same.

Internal app calculations use metric or NOAA-normalized metric values. The packet uses:

- temperature: tenths of degrees Celsius
- wind speed: tenths of meters per second
- wind gust: tenths of meters per second
- precipitation probability: percent
- visibility: meters

The map page converts selected values to user-facing miles and miles per hour for display only.

### 6.7 Meaning of the Weather Variables
Temperature:
- forecast air temperature for the slot

Wind speed:
- forecast sustained wind for the slot

Wind gust:
- highest gust value represented for the slot

Precipitation probability:
- the greatest probability of precipitation found within the slot

Precipitation kind:
- internal packet category describing the likely precipitation type
- values include none/unknown, rain, snow, ice, and mixed

Precipitation intensity:
- internal packet category describing light, moderate, or heavy precipitation when discernible from NOAA text

Visibility:
- minimum visibility found within the slot, in meters

Hazard flags:
- compact risk flags used by the firmware
- include thunder risk, severe thunderstorm risk, winter precipitation risk, strong wind risk, low visibility risk, and freezing surface risk

### 6.8 How Slot Values Are Derived
For each field and slot, the app uses deterministic rules:

- temperature: overlap-weighted average
- wind speed: overlap-weighted average
- wind gust: slot maximum
- precipitation probability: slot maximum
- visibility: slot minimum

If no NOAA interval overlaps a slot, the app falls back to the interval whose midpoint is nearest the slot midpoint. If no usable value exists, the field remains missing.

For missing or offshore anchors, the packet currently uses a provisional missing-data convention:

- slot offsets remain valid at 0, 60, and 120 minutes
- the remaining slot fields are encoded as zero

## 7. NORMAL SYSTEM BEHAVIOR

### 7.1 BLE Discovery and Connection
When the app starts and Bluetooth is on, it begins scanning automatically. When the `WeatherComputer` is found, the app connects automatically, discovers services and characteristics, and enables notifications.

### 7.2 Reconnect Behavior
If the WeatherComputer disconnects, the app returns to scanning automatically. If iOS restores BLE state, the app stores the restored peripheral and resumes BLE work only after the central is fully powered on.

### 7.3 Position Send Cadence
Position transmission is event-driven but scheduled against elapsed time since the last accepted position send. The intended operating cadence is approximately every 10 minutes while the app is active or otherwise receiving relevant events.

### 7.4 Weather Send Behavior
Weather is not resent continuously. The app tracks whether a newer weather field has been fetched and built since the last accepted weather send.

Normal behavior:

- newer weather exists: send weather first, then position
- no newer weather exists: send position only

This prevents repeated transmission of unchanged weather solely because a new position cycle occurs.

### 7.5 Acknowledgement Handling
The WeatherComputer returns an `AckV1`. The app decodes it and displays:

- ACK status
- echoed sequence
- active weather timestamp
- active position timestamp

Position and weather acceptance are tracked separately.

### 7.6 Weather Map Update Behavior
The `Weather Field Map` page updates when a new weather field is fetched and built. The slot selector changes which forecast slot is rendered without requiring a new NOAA fetch.

### 7.7 Location Updates and Send Checks
A new location update does not automatically guarantee transmission. Instead, it triggers a "send if due" evaluation. The actual send occurs only if cadence, BLE readiness, and fix freshness conditions are met.

## 8. TROUBLESHOOTING

### 8.1 WeatherComputer Not Found
Possible causes:

- WeatherComputer is not powered
- WeatherComputer is not advertising
- Bluetooth is off on the iPhone
- phone is out of BLE range
- another central device has already connected to the WeatherComputer

Corrective actions:

1. Confirm device power.
2. Confirm BLE advertising is active.
3. Confirm the device name is `WeatherComputer`.
4. Move the phone closer to the device.
5. Verify Bluetooth is enabled in iPhone settings.
6. Reopen the app and observe the scan status.

### 8.2 BLE Disconnects
Expected behavior:

- the app logs the disconnect
- the app returns to scanning
- the app attempts to reconnect automatically

Corrective actions:

1. Keep the app open.
2. Verify the WeatherComputer remains powered.
3. Confirm BLE range and antenna environment.
4. Wait for the app to return to `Ready`.

If the disconnect occurs repeatedly, reduce distance and remove likely RF obstructions.

### 8.3 No Location Fix
Possible causes:

- Location permission denied
- poor GPS reception
- the phone has not yet established a fix

Corrective actions:

1. Confirm Location Services are enabled.
2. Grant When In Use location permission.
3. If background behavior is desired, grant Always authorization when requested.
4. Move to an area with better sky view or signal conditions.

### 8.4 No Weather Data Appears
Possible causes:

- no valid live location fix exists
- internet connectivity to NOAA is unavailable
- NOAA returned errors for the selected anchor coordinates
- all nine anchor fetches failed

Corrective actions:

1. Confirm a current location fix exists.
2. Confirm internet connectivity on the phone.
3. Use `Fetch NOAA 3x3 Field` again from the `Weather Debug` page.
4. Review anchor-level errors on the debug page.

### 8.5 Southern or Offshore Anchors Fail
Observed behavior in the implemented system shows that some anchors may fail with `404` or missing `forecastGridData`, especially when the 120-mile spacing places anchors offshore or outside NOAA-supported coverage for the test location.

This is expected under the current canonical policy because the app intentionally uses the actual anchor coordinate rather than snapping to a nearby supported land node.

### 8.6 Map Not Displaying Weather Field
Possible causes:

- no 3 x 3 field has been fetched yet
- all anchors failed
- the map page was opened before weather data was built

Corrective actions:

1. Open `Weather Debug`.
2. Select `Fetch NOAA 3x3 Field`.
3. Confirm that anchors and packet debug data populate.
4. Return to `Weather Field Map`.

### 8.7 Weather Packet Will Not Send
Possible causes:

- BLE not ready
- weather packet length invalid
- no current weather field available
- another weather transfer already in progress
- a position packet is still awaiting ACK

Corrective actions:

1. Confirm main status is `Ready`.
2. Confirm the weather packet length is reported as valid.
3. Re-fetch the weather field if necessary.
4. Wait for outstanding ACK activity to clear.

## 9. OPERATIONAL LIMITATIONS

### 9.1 NOAA Dependency
Regional weather depends on NOAA API availability and network access from the iPhone. If NOAA cannot be reached, the app cannot build a fresh weather field.

### 9.2 Coverage Limitations
Some anchor coordinates may fall offshore or outside useful NOAA grid coverage for the selected center location. Under current policy, those anchors are not snapped to nearby forecast nodes.

### 9.3 Forecast Resolution
The field is intentionally coarse:

- 3 x 3 spatial grid
- 120-mile anchor spacing
- three one-hour forecast slots

This is a regional approximation, not a high-resolution local forecast product.

### 9.4 Forecast Horizon
The implemented forecast horizon is limited to approximately 180 minutes from the shared field anchor time.

### 9.5 BLE Range and Throughput
BLE performance depends on range, interference, and connection quality. The 470-byte weather packet is sent in ordered chunks to fit BLE transport limits. Loss of connection during chunk transmission can interrupt the transfer.

### 9.6 Background Operation
The app includes background scaffolding for location and BLE central operation, but iPhone background execution remains system-managed. Continuous unattended operation is not guaranteed solely by enabling permissions and background modes.

### 9.7 Weather Fetch Initiation
As currently implemented, new NOAA weather retrieval is initiated through the `Weather Debug` page. Normal transmission can include newer weather automatically only after that weather has been fetched and built in the app.

## 10. SAFETY / RELIABILITY NOTES

### 10.1 Data Freshness
Position and weather data may age between acquisition and use. The app tracks accepted sends and source age, but the operator should still regard displayed and transmitted weather as time-sensitive.

### 10.2 Forecast Uncertainty
NOAA forecast grid data is forecast information, not direct observation. Conditions may differ materially from the forecast, especially near terrain, coastlines, convective weather, or fast-changing fronts.

### 10.3 BLE Reliability
BLE links are short-range and can be disrupted by:

- distance
- shielding
- interference
- power interruption

Packet ACK status should be treated as the authoritative indication that a send succeeded.

### 10.4 Missing Weather Cells
When an anchor has no usable weather data, the current packet convention sends valid slot offsets with zeroed data fields. This preserves packet structure but does not imply benign weather at that anchor.

### 10.5 Hazard Interpretation
Hazard flags are conservative derived indicators, not a complete warning product. They are useful for onboard reasoning, but they do not replace official forecasts, warnings, or pilot/operator judgment.

## 11. GLOSSARY

BLE:
Bluetooth Low Energy. The short-range wireless link used between the iPhone and WeatherComputer.

NOAA:
National Oceanic and Atmospheric Administration. The source of the gridded weather forecast data used by the app.

Gridpoint Forecast:
A forecast data product tied to a forecast grid location and represented as time-varying values across intervals.

Regional Weather Field:
A 3 x 3 set of anchor forecasts centered on a selected location and intended to represent surrounding conditions, not just one point.

Anchor:
One of the nine geographic points in the 3 x 3 field. Anchors are named by row and column, for example `r1c2`.

Field Center:
The latitude and longitude about which the 3 x 3 anchor grid is constructed.

Forecast Slot:
One of the three one-hour forecast windows represented in the field: 0, 60, or 120 minutes from field anchor time.

RegionalSnapshotV1:
The 470-byte regional weather packet sent from the iPhone app to the WeatherComputer.

PositionUpdateV1:
A 32-byte position packet containing live phone location information.

AckV1:
The acknowledgement packet sent by the WeatherComputer in response to a received packet.

ForecastGridData:
The NOAA machine-readable weather data endpoint returned by `/points`.

Hazard Flags:
Compact bit flags in the weather packet that indicate derived operational risks such as thunder, winter precipitation, strong wind, low visibility, or freezing surface conditions.

Source Age:
The age, in minutes, of the weather source data relative to packet generation time.

## 12. SUMMARY OF OPERATOR USE

For routine use, the operator should follow this condensed sequence:

1. Power the WeatherComputer.
2. Open the WeatherRelay app.
3. Grant Bluetooth and location permissions.
4. Wait for the app to report `Ready`.
5. Confirm live position is available.
6. Open `Weather Debug` and fetch the 3 x 3 NOAA field when a fresh weather snapshot is required.
7. Use `Weather Field Map` to inspect the field spatially if needed.
8. Allow the app to continue its normal 10-minute position send cycle.
9. Observe ACK status to confirm accepted sends.

Under current implementation, this sequence provides the WeatherComputer with:

- recurring accepted position updates
- accepted regional weather snapshots whenever newer weather has been fetched and is available for the next send cycle

