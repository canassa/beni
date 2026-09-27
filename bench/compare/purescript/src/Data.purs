module Data (run) where

-- Records of records, record updates, list pipelines, grouping and sorting
-- over a small employee table.

import Prelude

import Data.Foldable (any, elem, foldl, sum)
import Data.FunctorWithIndex (mapWithIndex)
import Data.List (List(..), concatMap, filter, fromFoldable, length, reverse, snoc, sortBy, take, (:))
import Data.Maybe (Maybe(..))
import Data.Monoid (power)
import Data.String (joinWith)
import Data.Array as Array
import Data.Tuple (Tuple(..))

type Address =
  { city :: String
  , country :: String
  }

type Salary =
  { base :: Int
  , bonus :: Int
  }

type Employee =
  { id :: Int
  , name :: String
  , dept :: String
  , address :: Address
  , salary :: Salary
  , skills :: List String
  , active :: Boolean
  }

type DeptSummary =
  { dept :: String
  , headcount :: Int
  , payroll :: Int
  , topEarner :: String
  , cities :: List String
  }

type SkillCount =
  { skill :: String
  , count :: Int
  , firstSeen :: Int
  }

employee :: Int -> String -> String -> String -> String -> Int -> Int -> Array String -> Boolean -> Employee
employee id name dept city country base bonus skills active =
  { id
  , name
  , dept
  , address: { city, country }
  , salary: { base, bonus }
  , skills: fromFoldable skills
  , active
  }

employees :: List Employee
employees = fromFoldable
  [ employee 1 "Ada" "Engineering" "London" "UK" 120 30 [ "zig", "elm", "sql" ] true
  , employee 2 "Grace" "Engineering" "New York" "US" 135 25 [ "cobol", "sql" ] true
  , employee 3 "Linus" "Engineering" "Helsinki" "FI" 110 10 [ "c", "git" ] false
  , employee 4 "Barbara" "Research" "Boston" "US" 140 40 [ "clu", "sql", "elm" ] true
  , employee 5 "Edsger" "Research" "Austin" "US" 125 5 [ "algol", "proofs" ] true
  , employee 6 "Margaret" "Operations" "Boston" "US" 115 20 [ "apollo", "c" ] true
  , employee 7 "Ken" "Operations" "Berkeley" "US" 105 15 [ "c", "unix", "go" ] true
  , employee 8 "Dennis" "Operations" "Berkeley" "US" 105 15 [ "c", "unix" ] false
  , employee 9 "Frances" "Research" "Toronto" "CA" 130 35 [ "fortran", "proofs" ] true
  , employee 10 "Alan" "Research" "Manchester" "UK" 145 0 [ "proofs", "math" ] true
  , employee 11 "Radia" "Engineering" "Seattle" "US" 128 22 [ "networks", "sql" ] true
  , employee 12 "John" "Sales" "London" "UK" 90 60 [ "excel" ] true
  , employee 13 "Hedy" "Sales" "Vienna" "AT" 95 55 [ "radio", "excel" ] true
  , employee 14 "Katherine" "Research" "Hampton" "US" 118 12 [ "math", "fortran" ] true
  , employee 15 "Guido" "Engineering" "Amsterdam" "NL" 122 18 [ "python", "c" ] true
  , employee 16 "Yukihiro" "Engineering" "Matsue" "JP" 119 21 [ "ruby", "c" ] false
  , employee 17 "Anders" "Sales" "Copenhagen" "DK" 88 70 [ "pascal", "excel" ] true
  , employee 18 "Evan" "Engineering" "Copenhagen" "DK" 117 19 [ "elm", "haskell" ] true
  , employee 19 "Rich" "Operations" "Durham" "US" 101 9 [ "lisp", "sql" ] true
  , employee 20 "Joe" "Operations" "Stockholm" "SE" 99 11 [ "erlang", "networks" ] true
  ]

-- SINGLE-RECORD TRANSFORMS

totalPay :: Employee -> Int
totalPay person = person.salary.base + person.salary.bonus

giveRaise :: Int -> Employee -> Employee
giveRaise percent person =
  person { salary { base = person.salary.base + person.salary.base * percent / 100 } }

relocate :: String -> String -> Employee -> Employee
relocate city country person =
  person { address { city = city, country = country } }

addSkill :: String -> Employee -> Employee
addSkill skill person =
  if elem skill person.skills then
    person
  else
    person { skills = snoc person.skills skill }

describe :: Employee -> String
describe person =
  person.name
    <> " ("
    <> person.dept
    <> ", "
    <> person.address.city
    <> ") "
    <> show (totalPay person)

-- ORDERING

byPayDescending :: Employee -> Employee -> Ordering
byPayDescending a b = case compare (totalPay b) (totalPay a) of
  EQ -> compare a.id b.id
  other -> other

bySummary :: DeptSummary -> DeptSummary -> Ordering
bySummary a b = case compare b.payroll a.payroll of
  EQ -> compare b.headcount a.headcount
  other -> other

bySkillCount :: SkillCount -> SkillCount -> Ordering
bySkillCount a b = case compare b.count a.count of
  EQ -> compare a.firstSeen b.firstSeen
  other -> other

-- GROUPING

groupByDept :: List Employee -> List (Tuple String (List Employee))
groupByDept people =
  foldl addToGroup Nil people
    # map (\(Tuple dept members) -> Tuple dept (reverse members))
    # reverse

addToGroup :: List (Tuple String (List Employee)) -> Employee -> List (Tuple String (List Employee))
addToGroup groups person =
  if any (\(Tuple dept _) -> dept == person.dept) groups then
    map
      ( \(Tuple dept members) ->
          if dept == person.dept then
            Tuple dept (person : members)
          else
            Tuple dept members
      )
      groups
  else
    Tuple person.dept (person : Nil) : groups

distinct :: List String -> List String
distinct items =
  foldl
    ( \seen item ->
        if elem item seen then
          seen
        else
          snoc seen item
    )
    Nil
    items

summarize :: Tuple String (List Employee) -> DeptSummary
summarize (Tuple dept members) =
  let
    top =
      foldl
        ( \best person -> case best of
            Nothing -> Just person
            Just current ->
              if totalPay person > totalPay current then
                Just person
              else
                Just current
        )
        Nothing
        members
  in
    { dept
    , headcount: length members
    , payroll: sum (map totalPay members)
    , topEarner: case top of
        Just person -> person.name
        Nothing -> "nobody"
    , cities: distinct (map (\person -> person.address.city) members)
    }

countSkills :: List Employee -> List SkillCount
countSkills people =
  people
    # concatMap _.skills
    # mapWithIndex (\index skill -> Tuple index skill)
    # foldl bumpSkill Nil
    # sortBy bySkillCount

bumpSkill :: List SkillCount -> Tuple Int String -> List SkillCount
bumpSkill counts (Tuple index skill) =
  if any (\entry -> entry.skill == skill) counts then
    map
      ( \entry ->
          if entry.skill == skill then
            entry { count = entry.count + 1 }
          else
            entry
      )
      counts
  else
    snoc counts { skill, count: 1, firstSeen: index }

-- REPORTS

showSummary :: DeptSummary -> String
showSummary summary =
  summary.dept
    <> ": "
    <> show summary.headcount
    <> " people, payroll "
    <> show summary.payroll
    <> ", top "
    <> summary.topEarner
    <> ", cities "
    <> joinWith "/" (Array.fromFoldable summary.cities)

showSkill :: SkillCount -> String
showSkill entry = entry.skill <> " " <> power "#" entry.count

countryTotals :: List Employee -> List (Tuple String Int)
countryTotals people =
  foldl
    ( \totals person ->
        if any (\(Tuple country _) -> country == person.address.country) totals then
          map
            ( \(Tuple country total) ->
                if country == person.address.country then
                  Tuple country (total + totalPay person)
                else
                  Tuple country total
            )
            totals
        else
          snoc totals (Tuple person.address.country (totalPay person))
    )
    Nil
    people
    # sortBy (\(Tuple _ a) (Tuple _ b) -> compare b a)

run :: List String
run =
  let
    active = filter _.active employees

    raised =
      active
        # map (giveRaise 10)
        # map
            ( \person ->
                if person.dept == "Sales" then
                  relocate "Remote" "XX" person
                else
                  person
            )
        # map (addSkill "beni")

    top =
      raised
        # sortBy byPayDescending
        # take 5
        # map describe

    summaries =
      groupByDept raised
        # map summarize
        # sortBy bySummary
        # map showSummary

    skills =
      countSkills employees
        # take 6
        # map showSkill

    countries =
      countryTotals raised
        # map (\(Tuple country total) -> country <> "=" <> show total)

    payroll = sum (map totalPay raised)

    wellPaid = length (filter (\person -> totalPay person >= 150) raised)
  in
    fromFoldable
      [ "active " <> show (length active) <> " of " <> show (length employees)
      , "payroll " <> show payroll <> " well-paid " <> show wellPaid
      ]
      <> top
      <> summaries
      <> skills
      <> fromFoldable [ joinWith " " (Array.fromFoldable countries) ]
