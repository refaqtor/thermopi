import karax / [vdom, vstyles, kdom, karax, karaxdsl, kajax, jstrutils, compact, jjson, jdict]
import jsffi except `&`
import random, sequtils, strutils, times
import chartjs, momentjs, url_js
import temperature_units, times

type
  Views = enum
    Main

  Sensor = object
    id: int
    name: cstring

  Window = enum
    T1h, T12h, T24h, T48h, T7days, T30days

  HvacMode = enum NoControl, Heating, Cooling

  HvacStatus = enum Off, On

const
  httpApi = if defined(local): cstring"http://localhost:8080/api"
            else: cstring"http://thermopi:8080/api"

let
  LF = cstring"" & "\n"

var
  currentView = Main
  currentWindow = T24h

  currentSensor: int = 1     # currently selected sensor
  sensors: seq[Sensor] = @[] # list of sensors

  currentTime: int          # seconds since epoch
  currentTemperature: float # in Celcius

  mainSensorTemperature: float  # in Celcius
  desiredTemperature:    float  # in Celcius

  currentHvacMode = NoControl
  currentHvacStatus = Off

  upcomingTime: int          # seconds since epoc
  upcomingTemperature: float # in Celcius

  overrideTemperature: float # in Celcius
  overrideUntil: int64       # seconds since epoc

  forceHvac: cstring = ""

  currentUnit = Fahrenheit

  stubSensors = defined(stubs) # set to true when testing without a live server
  initialized = false # set to true after the first postRender()

  chart: Chart # temperature chart

## Forward definitions
proc loadChartData()
proc loadCurrentTemperature()

proc getCurrentSensor(): Sensor =
  for s in sensors:
    if s.id == currentSensor: return s

proc setCurrentSensor(s: Sensor) =
  currentSensor = s.id

proc getSensorByName(name: cstring): Sensor =
  for s in sensors:
    if s.name == name: return s

proc durationInSeconds(w: Window): int =
  case w
  of T1h:  60 * 60
  of T12h: 12 * 60 * 60
  of T24h: 24 * 60 * 60
  of T48h: 48 * 60 * 60
  of T7days: 7 * 24 * 60 * 60
  of T30days: 30 * 24 * 60 * 60

##
## Force HVAC
##

proc afterForceHvac(httpStatus: int, response: cstring) =
  # refresh
  loadCurrentTemperature()

proc setForceHvac(newState: cstring) =
  if stubSensors:
    forceHvac = newState
    afterForceHvac(200, "")
  else:
    ajaxPost(httpApi & "/forceHvac", @[], newState, afterForceHvac)

proc clearForceHvac() = setForceHvac("")
proc forceHvacOn()    = setForceHvac("On")
proc forceHvacOff()   = setForceHvac("Off")

##
## Override stuff
##

proc afterOverrideChange(httpStatus: int, response: cstring) =
  # refresh
  loadCurrentTemperature()

proc setOverride(newTemperature: float, newTimeUntil: int64) =
  if stubSensors:
    overrideTemperature = newTemperature
    overrideUntil = newTimeUntil
    afterOverrideChange(200, "")
  else:
    var body = ""
    body &= $newTemperature & "\n"
    body &= $newTimeUntil & "\n"
    ajaxPost(httpApi & "/override", @[], body, afterOverrideChange)

proc clearOverride() = setOverride(0.0, 0)

proc comfortOneHour() =
  let now = epochTime().int
  setOverride(fahrenheitToCelcius(67), now + (60 * 60))

proc workFromHome() =
  var t = getTime().local()
  setOverride(fahrenheitToCelcius(67), t.at(21, 30, 0).toTime.toUnix)

proc comfortForGuests() =
  var t = getTime().local()
  setOverride(fahrenheitToCelcius(68), t.at(23, 0, 0).toTime.toUnix)

proc awayForWeekend() =
  var t = getTime().local()
  while t.weekday != dSun:
    t = (t.toTime() + 1.days).local()
  setOverride(fahrenheitToCelcius(52), t.at(18, 0, 0).toTime.toUnix)

proc awayFor30Days() =
  var t = getTime().local()
  t = (t.toTime() + 1.months).local()
  setOverride(fahrenheitToCelcius(52), t.at(23, 59, 0).toTime.toUnix)

proc overrideAdjustTemperature(difference: float) =
  let baseTemperature =
    if overrideUntil == 0: desiredTemperature else: overrideTemperature
  let newTemperature = case currentUnit
    of Celcius: baseTemperature + difference
    of Fahrenheit: baseTemperature + (difference / 1.8)
  let newUntil = max(overrideUntil, epochTime().int + (60 * 60))
  setOverride(newTemperature, newUntil)

proc overrideAddTime(difference: int) =
  if overrideUntil != 0:
    setOverride(overrideTemperature, overrideUntil + difference)

##
##
##

proc createDom(data: RouterData): VNode =
  ## main renderer

  let params = queryParams()

  let window = params.get("window")
  if   window == "1h":     currentWindow = T1h
  elif window == "12h":    currentWindow = T12h
  elif window == "24h":    currentWindow = T24h
  elif window == "48h":    currentWindow = T48h
  elif window == "7days":  currentWindow = T7days
  elif window == "30days": currentWindow = T30days
  echo "currentWindow: " & $currentWindow

  let beforeUnit = currentUnit
  if data.hashPart == "#celcius": currentUnit = Celcius
  elif data.hashPart == "#fahrenheit": currentUnit = Fahrenheit
  if currentUnit != beforeUnit: loadChartData()

  var part = cstring""
  if data.hashPart.len > 1:
    part = data.hashPart.split(cstring"#")[1]
  echo "part: " & part

  if part != "":
    let hashSensor = getSensorByName(part)
    echo "hashSensor: " & $hashSensor
    if hashSensor.id != 0 and currentSensor != hashSensor.id:
      currentSensor = hashSensor.id
      loadCurrentTemperature()
      loadChartData()

  case currentView
  of Main:
    buildHtml(tdiv(class="thermopi-wrapper")):

      # hero
      section(class = "hero is-medium is-dark"):
        tdiv(class = "container"):
          h1(class = "title"):
            text "ThermoPi"

      # columns
      section():
        tdiv(class = "columns is-centered"):

          tdiv(class = "column"):
            tdiv(class = "card"):
              tdiv(class = "card-content"):
                section(class = "sensors", id = "sensors"):
                  tdiv(class = "container"):
                    ol:
                      for s in sensors:
                        li(value = $s.id):
                          a(href="#" & $s.name):
                            text $s.name
                            if currentSensor == s.id:
                              text " [*]"

          tdiv(class = "column"):
            tdiv(class = "card"):
              tdiv(class = "card-content has-text-centered"):
                section(class = "current-sensor"):
                  text getCurrentSensor().name
                section(class = "current-temperature is-size-1"):
                  tdiv(id="currentTemperature"):
                    text format(currentTemperature, currentUnit)
                section(class = "current-time"):
                  tdiv(id="currentTime"):
                    text fromUnix(currentTime).format(cstring"dddd, h:mm a")
                    if currentTime < epochTime().int - 600:
                      text "  [?????]"
                section(class = "temperature-units"):
                  tdiv(id="units"):
                    case currentUnit
                    of Celcius:
                      a(href="#fahrenheit"):
                        text "[Switch to Fahrenheit]"
                    of Fahrenheit:
                      a(href="#celcius"):
                        text "[Switch to Celcius]"

          tdiv(class = "column"):
            tdiv(class = "card"):
              tdiv(class = "card-content has-text-centered"):
                section(class = "current-hvac-mode"):
                  text $currentHvacMode & ": " & $currentHvacStatus
                section(class = "desired-temperature"):
                  tdiv(id="mainSensorTemperature"):
                    text "Current: " & format(mainSensorTemperature, currentUnit)
                  if overrideUntil == 0:
                    tdiv(id="desiredTemperature"):
                      text "Desired: " & format(desiredTemperature, currentUnit)
                      button:
                        text "+1"
                        proc onclick(ev: Event; n: VNode) = overrideAdjustTemperature(1)
                      button:
                        text "-1"
                        proc onclick(ev: Event; n: VNode) = overrideAdjustTemperature(-1)
                  if forceHvac != cstring"":
                    tdiv(id="forceHvac"):
                      strong:
                        text "Force HVAC: " & forceHvac
                        button:
                          text "Clear"
                          proc onclick(ev: Event; n: VNode) = clearForceHvac()
                  elif overrideUntil == 0:
                    tdiv(id="upcomingTemperature"):
                      text "Next: " & format(upcomingTemperature, currentUnit) & " @"
                    tdiv(id="upcomingTime"):
                      text fromUnix(upcomingTime).format(cstring"dddd, h:mm a")
                  else:
                    tdiv(id="overrideTemperature"):
                      strong:
                        text "Override: " & format(overrideTemperature, currentUnit)
                      button:
                        text "+1"
                        proc onclick(ev: Event; n: VNode) = overrideAdjustTemperature(1)
                      button:
                        text "-1"
                        proc onclick(ev: Event; n: VNode) = overrideAdjustTemperature(-1)
                      text "until"
                    tdiv(id="overrideUntil"):
                      let now = epochTime().int64
                      if overrideUntil - now > 7 * 24 * 60 * 60:
                        strong:
                          text fromUnix(overrideUntil.int).format(cstring"MMM D")
                      else:
                        strong:
                          text fromUnix(overrideUntil.int).format(cstring"dddd, h:mm a")
                    tdiv:
                      button:
                        text "+1h"
                        proc onclick(ev: Event; n: VNode) = overrideAddTime(60 * 60)
                      button:
                        text "+1d"
                        proc onclick(ev: Event; n: VNode) = overrideAddTime(24 * 60 * 60)
                      button:
                        text "Clear"
                        proc onclick(ev: Event; n: VNode) = clearOverride()

      # actions
      section():
        tdiv(class = "columns is-centered"):

          tdiv(class = "column has-text-centered"):
            button(class = "button"):
              text "Comfort for 1 Hour"
              proc onclick(ev: Event; n: VNode) = comfortOneHour()
          tdiv(class = "column has-text-centered"):
            button(class = "button"):
              text "Work From Home"
              proc onclick(ev: Event; n: VNode) = workFromHome()
          tdiv(class = "column has-text-centered"):
            button(class = "button"):
              text "Guests Overnight"
              proc onclick(ev: Event; n: VNode) = comfortForGuests()
          tdiv(class = "column has-text-centered"):
            button(class = "button"):
              text "Away for Weekend"
              proc onclick(ev: Event; n: VNode) = awayForWeekend()
          tdiv(class = "column has-text-centered"):
            button(class = "button"):
              text "Away"
              proc onclick(ev: Event; n: VNode) = awayFor30Days()


        tdiv(class = "columns is-centered"):
          tdiv(class = "column has-text-centered"):

            section(class = "window"):
              text "Window"
              text " "
              a(href="?window=1h"):
                text "1h"
              text " "
              a(href="?window=12h"):
                text "12h"
              text " "
              a(href="?window=24h"):
                text "24h"
              text " "
              a(href="?window=48h"):
                text "48h"
              text " "
              a(href="?window=7days"):
                text "7d"
              text " "
              a(href="?window=30days"):
                text "30d"

            section(class = "graph", id = "graph"):
              tdiv(class="chart-container", id="chart-div", style = style(StyleAttr.position, cstring"relative")): #position: relative; height:40vh; width:80vw"):
                canvas(id = "chart")
        tdiv(class = "columns is-centered"):
          tdiv(class = "column has-text-centered"):
            text "Force HVAC"
            button:
              text "On"
              proc onclick(ev: Event; n: VNode) = forceHvacOn()
            button:
              text "Off"
              proc onclick(ev: Event; n: VNode) = forceHvacOff()
            button:
              text "Clear"
              proc onclick(ev: Event; n: VNode) = clearForceHvac()

proc sensorsLoaded(httpStatus: int, response: cstring) =
  ## ajaxGet callback
  sensors = @[]
  let lines: seq[cstring] = response.split(LF)
  for i in 0 ..< lines.len div 2:
    let id: int = lines[i*2].parseInt
    let name: cstring = lines[i*2+1]
    let s = Sensor(id: id, name: name)
    sensors.add(s)
  redraw(kxi)

proc fakeSensorsLoad() =
  ## generates dummy data when testing witout a live server
  var str = cstring""
  str &= $1 & LF
  str &= "Living Room" & LF
  str &= $2& LF
  str &= "Garage" & LF
  str &= $3 & LF
  str &= "Exterior" & LF
  sensorsLoaded(200, str)

proc loadSensors() =
  if stubSensors:
    discard setTimeout(fakeSensorsLoad, 0)
  else:
    ajaxGet(httpApi & "/sensors", @[], sensorsLoaded)

proc updateChart(labels: openarray[cstring], temperatures: seq[float]) =
  var data: seq[float] = temperatures
  if currentUnit == Fahrenheit:
    data = data.mapIt(celciusToFahrenheit(it))
  let ctx = document.getElementById(cstring"chart")
  let options = %*{
    "type": "line",
    "data": {
      "labels": labels,
      "datasets": [{
          "label": "Temperature",
          "data": data,
          "backgroundColor": "rgba(255, 99, 32, 0.2)",
          "borderColor": "rgba(255,99,132,1)",
          "borderWidth": 1
        }]
    },
    "options": {
      "responsive": true,
      "maintainAspectRatio": true,
      "legend": {
        "display": false
      },
      "scales": {
        "xAxes": [{
          "display": true,
          "scaleLabel": {
            "display": true,
            "labelString": "Time"
          }
        }],
        "yAxes": [{
          "display": true,
          "scaleLabel": {
            "display": true,
            "labelString": "Temperature"
          }
        }]
      }

    }
  }
  chart = newChart(ctx, options)

## Current temperature

proc currentTemperatureLoaded(httpStatus: int, response: cstring, sensor: int) =
  ## ajaxGet() callback
  echo response
  let lines: seq[cstring] = response.split(LF)
  currentTime = lines[0].parseInt
  currentTemperature = lines[1].parseFloat
  currentHvacMode =
    if   lines[2] == cstring"Heating": Heating
    elif lines[2] == cstring"Cooling": Cooling
    else: NoControl
  currentHvacStatus = if lines[3] == cstring"On": On else: Off
  mainSensorTemperature = lines[4].parseFloat
  desiredTemperature = lines[5].parseFloat
  upcomingTime = lines[6].parseInt
  upcomingTemperature = lines[7].parseFloat
  overrideTemperature = lines[8].parseFloat
  overrideUntil = lines[9].parseInt
  forceHvac = lines[10]
  redraw(kxi)

proc currentTemperatureLoaded(sensor: int): proc (httpStatus: int, response: cstring) =
  ## returns a closure that curries `sensor` parameter
  result = proc (httpStatus: int, response: cstring) =
    currentTemperatureLoaded(httpStatus, response, sensor)

proc randomCelcius(): float =
  10.float + random(10).float + random(10) / 10

proc fakeCurrentTemperatureLoad() =
  ## generates dummy data when testing witout a live server
  var response = cstring""
  let now = epochTime().int64
  response &= $now & LF # currentTime
  response &= $randomCelcius() & LF # currentTemperature
  response &= "Heating" & LF # currentHvacMode
  response &= "On" & LF # currentHvacStatus
  response &= $randomCelcius() & LF # mainSensorTemperature
  response &= $randomCelcius() & LF # desiredTemperature
  response &= $now & LF # upcomingTime
  response &= $randomCelcius() & LF # upcomingTemperature
  currentTemperatureLoaded(httpStatus = 200, response, sensor = currentSensor)

proc loadCurrentTemperature() =
  if stubSensors:
    discard setTimeout(fakeCurrentTemperatureLoad, 0)
  else:
    ajaxGet(httpApi & "/current/" & $currentSensor, @[], currentTemperatureLoaded(currentSensor))

proc periodicLoadCurrentTemperature() =
  discard setTimeout(periodicLoadCurrentTemperature, 30000)
  loadCurrentTemperature()

## Chart data

proc chartDataLoaded(httpStatus: int, response: cstring, sensor: int) =
  ## ajaxGet() callback
  var labels: seq[cstring] = @[]
  var temperatures: seq[float] = @[]
  let lines: seq[cstring] = response.split(LF)
  for i in 0 ..< lines.len div 2:
    let epoch: int = lines[i*2].parseInt
    let temp: float = lines[i*2+1].parseFloat
    labels.add(fromUnix(epoch).format(cstring"dddd, h:mm a"))
    temperatures.add(temp)
  updateChart(labels, temperatures)


proc chartDataLoaded(sensor: int): proc (httpStatus: int, response: cstring) =
  ## returns a closure that curries `sensor` parameter
  result = proc (httpStatus: int, response: cstring) =
    chartDataLoaded(httpStatus, response, sensor)

proc fakeChartDataLoad() =
  ## generates dummy data when testing witout a live server
  let now = epochTime().int64
  let samplePeriod = 30
  let start = now - 100 * samplePeriod - samplePeriod
  var response = cstring""
  for i in 0 ..< 100:
    response &= $(start + i * samplePeriod) & LF
    response &= $randomCelcius() & LF
  chartDataLoaded(httpStatus = 200, response, sensor = currentSensor)

proc loadChartData() =
  if chart != nil: chart.clear()
  if stubSensors:
    discard setTimeout(fakeChartDataLoad, 0)
  else:
    let now = epochTime().int
    let start = now - durationInSeconds(currentWindow)
    let `end` = now
    var params = cstring"?"
    params &= "start=" & $start
    params &= "&end=" & $`end`
    ajaxGet(httpApi & "/temperature/" & $currentSensor & params, @[], chartDataLoaded(currentSensor))

proc postRender(data: RouterData) =
  if not initialized:
    loadSensors()
    loadChartData()
    periodicLoadCurrentTemperature()
  initialized = true

setRenderer createDom, "ROOT", postRender

setForeignNodeId "chart-div"