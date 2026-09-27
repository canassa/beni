// Records of records, record updates, list pipelines, grouping and sorting
// over a small employee table.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq}
import gleam/string

type Address {
  Address(city: String, country: String)
}

type Salary {
  Salary(base: Int, bonus: Int)
}

type Employee {
  Employee(
    id: Int,
    name: String,
    dept: String,
    address: Address,
    salary: Salary,
    skills: List(String),
    active: Bool,
  )
}

type DeptSummary {
  DeptSummary(
    dept: String,
    headcount: Int,
    payroll: Int,
    top_earner: String,
    cities: List(String),
  )
}

type SkillCount {
  SkillCount(skill: String, count: Int, first_seen: Int)
}

fn employee(
  id: Int,
  name: String,
  dept: String,
  city: String,
  country: String,
  base: Int,
  bonus: Int,
  skills: List(String),
  active: Bool,
) -> Employee {
  Employee(
    id: id,
    name: name,
    dept: dept,
    address: Address(city: city, country: country),
    salary: Salary(base: base, bonus: bonus),
    skills: skills,
    active: active,
  )
}

fn employees() -> List(Employee) {
  [
    employee(
      1,
      "Ada",
      "Engineering",
      "London",
      "UK",
      120,
      30,
      ["zig", "elm", "sql"],
      True,
    ),
    employee(
      2,
      "Grace",
      "Engineering",
      "New York",
      "US",
      135,
      25,
      ["cobol", "sql"],
      True,
    ),
    employee(
      3,
      "Linus",
      "Engineering",
      "Helsinki",
      "FI",
      110,
      10,
      ["c", "git"],
      False,
    ),
    employee(
      4,
      "Barbara",
      "Research",
      "Boston",
      "US",
      140,
      40,
      ["clu", "sql", "elm"],
      True,
    ),
    employee(
      5,
      "Edsger",
      "Research",
      "Austin",
      "US",
      125,
      5,
      ["algol", "proofs"],
      True,
    ),
    employee(
      6,
      "Margaret",
      "Operations",
      "Boston",
      "US",
      115,
      20,
      ["apollo", "c"],
      True,
    ),
    employee(
      7,
      "Ken",
      "Operations",
      "Berkeley",
      "US",
      105,
      15,
      ["c", "unix", "go"],
      True,
    ),
    employee(
      8,
      "Dennis",
      "Operations",
      "Berkeley",
      "US",
      105,
      15,
      ["c", "unix"],
      False,
    ),
    employee(
      9,
      "Frances",
      "Research",
      "Toronto",
      "CA",
      130,
      35,
      ["fortran", "proofs"],
      True,
    ),
    employee(
      10,
      "Alan",
      "Research",
      "Manchester",
      "UK",
      145,
      0,
      ["proofs", "math"],
      True,
    ),
    employee(
      11,
      "Radia",
      "Engineering",
      "Seattle",
      "US",
      128,
      22,
      ["networks", "sql"],
      True,
    ),
    employee(12, "John", "Sales", "London", "UK", 90, 60, ["excel"], True),
    employee(
      13,
      "Hedy",
      "Sales",
      "Vienna",
      "AT",
      95,
      55,
      ["radio", "excel"],
      True,
    ),
    employee(
      14,
      "Katherine",
      "Research",
      "Hampton",
      "US",
      118,
      12,
      ["math", "fortran"],
      True,
    ),
    employee(
      15,
      "Guido",
      "Engineering",
      "Amsterdam",
      "NL",
      122,
      18,
      ["python", "c"],
      True,
    ),
    employee(
      16,
      "Yukihiro",
      "Engineering",
      "Matsue",
      "JP",
      119,
      21,
      ["ruby", "c"],
      False,
    ),
    employee(
      17,
      "Anders",
      "Sales",
      "Copenhagen",
      "DK",
      88,
      70,
      ["pascal", "excel"],
      True,
    ),
    employee(
      18,
      "Evan",
      "Engineering",
      "Copenhagen",
      "DK",
      117,
      19,
      ["elm", "haskell"],
      True,
    ),
    employee(
      19,
      "Rich",
      "Operations",
      "Durham",
      "US",
      101,
      9,
      ["lisp", "sql"],
      True,
    ),
    employee(
      20,
      "Joe",
      "Operations",
      "Stockholm",
      "SE",
      99,
      11,
      ["erlang", "networks"],
      True,
    ),
  ]
}

// SINGLE-RECORD TRANSFORMS

fn total_pay(person: Employee) -> Int {
  person.salary.base + person.salary.bonus
}

fn give_raise(person: Employee, percent: Int) -> Employee {
  let salary = person.salary
  Employee(
    ..person,
    salary: Salary(..salary, base: salary.base + salary.base * percent / 100),
  )
}

fn relocate(person: Employee, city: String, country: String) -> Employee {
  Employee(..person, address: Address(city: city, country: country))
}

fn add_skill(person: Employee, skill: String) -> Employee {
  case list.contains(person.skills, skill) {
    True -> person
    False -> Employee(..person, skills: list.append(person.skills, [skill]))
  }
}

fn describe(person: Employee) -> String {
  person.name
  <> " ("
  <> person.dept
  <> ", "
  <> person.address.city
  <> ") "
  <> int.to_string(total_pay(person))
}

// ORDERING

fn by_pay_descending(a: Employee, b: Employee) -> Order {
  case int.compare(total_pay(b), total_pay(a)) {
    Eq -> int.compare(a.id, b.id)
    other -> other
  }
}

fn by_summary(a: DeptSummary, b: DeptSummary) -> Order {
  case int.compare(b.payroll, a.payroll) {
    Eq -> int.compare(b.headcount, a.headcount)
    other -> other
  }
}

fn by_skill_count(a: SkillCount, b: SkillCount) -> Order {
  case int.compare(b.count, a.count) {
    Eq -> int.compare(a.first_seen, b.first_seen)
    other -> other
  }
}

// GROUPING

fn group_by_dept(people: List(Employee)) -> List(#(String, List(Employee))) {
  list.fold(people, [], add_to_group)
  |> list.map(fn(group) { #(group.0, list.reverse(group.1)) })
  |> list.reverse
}

fn add_to_group(
  groups: List(#(String, List(Employee))),
  person: Employee,
) -> List(#(String, List(Employee))) {
  case list.any(groups, fn(group) { group.0 == person.dept }) {
    True ->
      list.map(groups, fn(group) {
        let #(dept, members) = group
        case dept == person.dept {
          True -> #(dept, [person, ..members])
          False -> #(dept, members)
        }
      })
    False -> [#(person.dept, [person]), ..groups]
  }
}

fn distinct(items: List(String)) -> List(String) {
  list.fold(items, [], fn(seen, item) {
    case list.contains(seen, item) {
      True -> seen
      False -> list.append(seen, [item])
    }
  })
}

fn summarize(group: #(String, List(Employee))) -> DeptSummary {
  let #(dept, members) = group
  let top =
    list.fold(members, None, fn(best: Option(Employee), person) {
      case best {
        None -> Some(person)
        Some(current) ->
          case total_pay(person) > total_pay(current) {
            True -> Some(person)
            False -> Some(current)
          }
      }
    })
  DeptSummary(
    dept: dept,
    headcount: list.length(members),
    payroll: int.sum(list.map(members, total_pay)),
    top_earner: case top {
      Some(person) -> person.name
      None -> "nobody"
    },
    cities: distinct(list.map(members, fn(person) { person.address.city })),
  )
}

fn count_skills(people: List(Employee)) -> List(SkillCount) {
  people
  |> list.flat_map(fn(person) { person.skills })
  |> list.index_map(fn(skill, index) { #(index, skill) })
  |> list.fold([], bump_skill)
  |> list.sort(by_skill_count)
}

fn bump_skill(
  counts: List(SkillCount),
  entry: #(Int, String),
) -> List(SkillCount) {
  let #(index, skill) = entry
  case list.any(counts, fn(existing) { existing.skill == skill }) {
    True ->
      list.map(counts, fn(existing) {
        case existing.skill == skill {
          True -> SkillCount(..existing, count: existing.count + 1)
          False -> existing
        }
      })
    False ->
      list.append(counts, [
        SkillCount(skill: skill, count: 1, first_seen: index),
      ])
  }
}

// REPORTS

fn show_summary(summary: DeptSummary) -> String {
  summary.dept
  <> ": "
  <> int.to_string(summary.headcount)
  <> " people, payroll "
  <> int.to_string(summary.payroll)
  <> ", top "
  <> summary.top_earner
  <> ", cities "
  <> string.join(summary.cities, "/")
}

fn show_skill(entry: SkillCount) -> String {
  entry.skill <> " " <> string.repeat("#", entry.count)
}

fn country_totals(people: List(Employee)) -> List(#(String, Int)) {
  list.fold(people, [], fn(totals: List(#(String, Int)), person: Employee) {
    case list.any(totals, fn(total) { total.0 == person.address.country }) {
      True ->
        list.map(totals, fn(total) {
          let #(country, amount) = total
          case country == person.address.country {
            True -> #(country, amount + total_pay(person))
            False -> #(country, amount)
          }
        })
      False ->
        list.append(totals, [#(person.address.country, total_pay(person))])
    }
  })
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
}

pub fn run() -> List(String) {
  let all = employees()
  let active = list.filter(all, fn(person) { person.active })
  let raised =
    active
    |> list.map(give_raise(_, 10))
    |> list.map(fn(person) {
      case person.dept == "Sales" {
        True -> relocate(person, "Remote", "XX")
        False -> person
      }
    })
    |> list.map(add_skill(_, "beni"))
  let top =
    raised
    |> list.sort(by_pay_descending)
    |> list.take(5)
    |> list.map(describe)
  let summaries =
    group_by_dept(raised)
    |> list.map(summarize)
    |> list.sort(by_summary)
    |> list.map(show_summary)
  let skills =
    count_skills(all)
    |> list.take(6)
    |> list.map(show_skill)
  let countries =
    country_totals(raised)
    |> list.map(fn(total) { total.0 <> "=" <> int.to_string(total.1) })
  let payroll = int.sum(list.map(raised, total_pay))
  let well_paid =
    list.length(list.filter(raised, fn(person) { total_pay(person) >= 150 }))
  list.flatten([
    [
      "active "
        <> int.to_string(list.length(active))
        <> " of "
        <> int.to_string(list.length(all)),
      "payroll "
        <> int.to_string(payroll)
        <> " well-paid "
        <> int.to_string(well_paid),
    ],
    top,
    summaries,
    skills,
    [string.join(countries, " ")],
  ])
}
