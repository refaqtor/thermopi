import karax / jstrutils
import math, times

type
  TemperatureUnit* = enum
    Celcius, Fahrenheit

proc celciusToFahrenheit*(c: float): float =
  math.round(c * 1.8 + 32, 2)

proc fahrenheitToCelcius*(f: float): float =
  math.round((f - 32) / 1.8, 2)

proc format*(celcius: float, unit: TemperatureUnit): cstring =
  case unit
  of Celcius:
    $math.round(celcius, 1) & "C"
  of Fahrenheit:
    $math.round(celciusToFahrenheit(celcius), 1) & "F"

proc at*(dt: DateTime, hour: int, minute: int, second: int): DateTime =
  initDateTime(dt.monthday, dt.month, dt.year, hour, minute, second)
