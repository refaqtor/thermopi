import options, os, times
import temperature, datetime
import db, tdata

when defined(controlPi):
  {.passL: "-lwiringPi".}
  import wiringPi

type
  ControlMode* = enum NoControl, Heating, Cooling

  HvacStatus* = enum Off, On

  ControlState* = object
    hvac*: HvacStatus
    lastTransition*: int64 # seconds since epoch

  DayTime* = object
    hour*: int
    min*: int

  Period* = object
    start*: DayTime
    desiredTemperature*: Temperature # celcius

  Schedule* = object
    weekday: seq[Period]
    weekend: seq[Period]


# Forward declarations
proc defaultControlMode(): ControlMode
proc calcDesiredTemperature(schedule: Schedule, dt: DateTime): Temperature

let
  hysteresis = 0.5 # celcius

  quietTime = 5 * 60 # seconds between on/off transition (duty-cycle control)

  mySchedule = Schedule(
    weekday: @[
      Period(start: DayTime(hour:  6, min:  0), desiredTemperature: fahrenheit(65)),
      Period(start: DayTime(hour:  9, min:  0), desiredTemperature: fahrenheit(62)),
      Period(start: DayTime(hour: 17, min:  0), desiredTemperature: fahrenheit(65)),
      Period(start: DayTime(hour: 21, min: 30), desiredTemperature: fahrenheit(58))
    ],
    weekend: @[
      Period(start: DayTime(hour:  6, min: 30), desiredTemperature: fahrenheit(65)),
      Period(start: DayTime(hour: 21, min: 30), desiredTemperature: fahrenheit(58))
    ]
  )

  heatingPin: cint = 0
  coolingPin: cint = 1

var
  controlState* = ControlState(hvac: Off, lastTransition: 0)
  controlMode* = defaultControlMode()

# General logic:
# - if heating mode and current temperature < desired, turn on heating
# - if cooling mode and current temperature > desired turn on AC
proc updateState(currentState: ControlState, currentMode: ControlMode, currentTime: int64,
  currentTemperature: Temperature, desiredTemperature: Temperature): ControlState =
  result = currentState

  case currentMode
  of NoControl:
    result.hvac = Off

  of Heating:
    if currentTemperature.toCelcius < (desiredTemperature.toCelcius - hysteresis):
      echo $currentTemperature.toCelcius
      echo $desiredTemperature.toCelcius
      echo $hysteresis
      echo $(desiredTemperature.toCelcius - hysteresis)
      if currentState.hvac == Off:
        if currentTime > (currentState.lastTransition + quietTime):
          result.lastTransition = currentTime
          result.hvac = On
    elif currentTemperature.toCelcius > (desiredTemperature.toCelcius + hysteresis):
      if currentState.hvac == On:  # no quietTime to turn off
        result.lastTransition = currentTime
        result.hvac = Off

  of Cooling:
    if currentTemperature.toCelcius > (desiredTemperature.toCelcius + hysteresis):
      if currentState.hvac == Off:
        if currentTime > (currentState.lastTransition + quietTime):
          result.lastTransition = currentTime
          result.hvac = On
    elif currentTemperature.toCelcius < (desiredTemperature.toCelcius - hysteresis):
      if currentState.hvac == On:  # no quietTime to turn off
        result.lastTransition = currentTime
        result.hvac = Off

proc initTControl*() =
  when defined(controlPi):
    if (wiringPiSetup() == -1):
      raise newException(OSError, "wiringPiSetup failed")
    heatingPin.pinMode(OUTPUT)
    coolingPin.pinMode(OUTPUT)

proc controlHvac(c: HvacStatus) =
  echo "Control HVAC: " & $controlMode & " -> " & $c

  case controlMode
  of NoControl:
    echo "No control - HvacStatus: " & $c
  of Heating:
    echo "Heating - HvacStatus: " & $c
    when defined(controlPi):
      if c == On:  digitalWrite(heatingPin, 1)
      if c == Off: digitalWrite(heatingPin, 0)
  of Cooling:
    echo "Cooling - HvacStatus: " & $c
    when defined(controlPi):
      if c == On:  digitalWrite(coolingPin, 1)
      if c == Off: digitalWrite(coolingPin, 0)

proc currentDesiredTemperature*(): Temperature =
  calcDesiredTemperature(mySchedule, getTime().local())

proc doControl*(currentTemperature: Temperature) =
  let currentTime = epochTime().int64
  let desiredTemperature = currentDesiredTemperature()
  echo "current temperature: " & currentTemperature.format(Fahrenheit)
  echo "desired temperature: " & desiredTemperature.format(Fahrenheit) & " +/- " & $(hysteresis * 1.8)

  let oldState = controlState

  controlState = updateState(
    controlState, controlMode, currentTime,
    currentTemperature, desiredTemperature)

  if controlMode != NoControl and oldState != controlState:
    controlHvac(controlState.hvac)


proc findPeriod(periods: seq[Period], dt: DateTime): Option[Period] =
  var i = periods.len - 1
  while i > 0:
    let p = periods[i]
    let h = p.start.hour
    let m = p.start.min
    if (h < dt.hour) or (h == dt.hour and m <= dt.minute):
      return some(p)
    i -= 1
  return none(Period)


proc periodAt(schedule: Schedule, dt: DateTime): Period =
  let periods = if dt.isWeekday(): schedule.weekday else: schedule.weekend
  findPeriod(periods, dt).get(otherwise = periodAt(schedule, yesterdayAtMidnight(dt)))

proc calcDesiredTemperature(schedule: Schedule, dt: DateTime): Temperature =
  periodAt(schedule, dt).desiredTemperature

proc upcomingPeriod(periods: seq[Period], dt: DateTime): Option[Period] =
  result = none(Period)
  var i = periods.len - 1
  while i > 0:
    let p = periods[i]
    let h = p.start.hour
    let m = p.start.min
    if (h < dt.hour) or (h == dt.hour and m <= dt.minute):
      return result
    result = some(p)
    i -= 1
  return result

proc upcomingPeriod(schedule: Schedule, dt: DateTime): (Period, DateTime) =
  let periods = if dt.isWeekday(): schedule.weekday else: schedule.weekend
  let period = upcomingPeriod(periods, dt)
  if period.isSome():
    let period = period.get()
    (period, dt.at(period.start.hour, period.start.min, 0))
  else:
    let tomorrow = tomorrowAtMidnight(dt)
    let periods = if tomorrow.isWeekday(): schedule.weekday else: schedule.weekend
    let period = periods[0]
    (period, tomorrow.at(period.start.hour, period.start.min, 0))

proc upcomingPeriod*(): (Period, DateTime) =
  upcomingPeriod(mySchedule, getTime().local())

proc isSummer(): bool =
  let t = getTime().local()
  case t.month
  of mMay, mJun, mJul, mAug, mSep: true
  else: false

proc isWinter(): bool =
  let t = getTime().local()
  case t.month
  of mNov, mDec, mJan, mFeb, mMar: true
  else: false

proc defaultControlMode(): ControlMode =
  if isSummer(): Cooling
  elif isWinter(): Heating
  else: NoControl


## Control loop

let mainSensorId* = 1 # e.g. living room
let checkpointPeriod = 10 * 60 # period, in seconds, to checkpoint database

proc controlLoop*(): void =
  {.gcsafe.}:
    var lastCheckpoint = 0.int64

    while true:
      sleep(5 * 1000)
      let now = epochTime().int64

      # turn HVAC system on/off based on current temperature of main sensor
      let sensorData = getLatestSensorData(mainSensorId)
      if sensorData.len > 0:
        let last = sensorData[0]
        if last.instant > (now - 5 * 60):
          let currentTemperature = celcius(last.temperature)
          doControl(currentTemperature)

      # checkpoit database
      if lastCheckpoint < now - checkpointPeriod:
        db.checkpoint()
        lastCheckpoint = now
