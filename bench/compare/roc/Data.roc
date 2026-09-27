module [run]

# Records of records, record updates, list pipelines, grouping and sorting
# over a small employee table.

Address : { city : Str, country : Str }

Salary : { base : I64, bonus : I64 }

Employee : {
    id : I64,
    name : Str,
    dept : Str,
    address : Address,
    salary : Salary,
    skills : List Str,
    active : Bool,
}

DeptSummary : {
    dept : Str,
    headcount : I64,
    payroll : I64,
    top_earner : Str,
    cities : List Str,
}

SkillCount : { skill : Str, count : I64, first_seen : I64 }

employee : I64, Str, Str, Str, Str, I64, I64, List Str, Bool -> Employee
employee = |id, name, dept, city, country, base, bonus, skills, active| {
    id,
    name,
    dept,
    address: { city, country },
    salary: { base, bonus },
    skills,
    active,
}

employees : List Employee
employees = [
    employee(1, "Ada", "Engineering", "London", "UK", 120, 30, ["zig", "elm", "sql"], Bool.true),
    employee(2, "Grace", "Engineering", "New York", "US", 135, 25, ["cobol", "sql"], Bool.true),
    employee(3, "Linus", "Engineering", "Helsinki", "FI", 110, 10, ["c", "git"], Bool.false),
    employee(4, "Barbara", "Research", "Boston", "US", 140, 40, ["clu", "sql", "elm"], Bool.true),
    employee(5, "Edsger", "Research", "Austin", "US", 125, 5, ["algol", "proofs"], Bool.true),
    employee(6, "Margaret", "Operations", "Boston", "US", 115, 20, ["apollo", "c"], Bool.true),
    employee(7, "Ken", "Operations", "Berkeley", "US", 105, 15, ["c", "unix", "go"], Bool.true),
    employee(8, "Dennis", "Operations", "Berkeley", "US", 105, 15, ["c", "unix"], Bool.false),
    employee(9, "Frances", "Research", "Toronto", "CA", 130, 35, ["fortran", "proofs"], Bool.true),
    employee(10, "Alan", "Research", "Manchester", "UK", 145, 0, ["proofs", "math"], Bool.true),
    employee(11, "Radia", "Engineering", "Seattle", "US", 128, 22, ["networks", "sql"], Bool.true),
    employee(12, "John", "Sales", "London", "UK", 90, 60, ["excel"], Bool.true),
    employee(13, "Hedy", "Sales", "Vienna", "AT", 95, 55, ["radio", "excel"], Bool.true),
    employee(14, "Katherine", "Research", "Hampton", "US", 118, 12, ["math", "fortran"], Bool.true),
    employee(15, "Guido", "Engineering", "Amsterdam", "NL", 122, 18, ["python", "c"], Bool.true),
    employee(16, "Yukihiro", "Engineering", "Matsue", "JP", 119, 21, ["ruby", "c"], Bool.false),
    employee(17, "Anders", "Sales", "Copenhagen", "DK", 88, 70, ["pascal", "excel"], Bool.true),
    employee(18, "Evan", "Engineering", "Copenhagen", "DK", 117, 19, ["elm", "haskell"], Bool.true),
    employee(19, "Rich", "Operations", "Durham", "US", 101, 9, ["lisp", "sql"], Bool.true),
    employee(20, "Joe", "Operations", "Stockholm", "SE", 99, 11, ["erlang", "networks"], Bool.true),
]

# SINGLE-RECORD TRANSFORMS

total_pay : Employee -> I64
total_pay = |person|
    person.salary.base + person.salary.bonus

give_raise : Employee, I64 -> Employee
give_raise = |person, percent|
    salary = person.salary
    { person & salary: { salary & base: salary.base + salary.base * percent // 100 } }

relocate : Employee, Str, Str -> Employee
relocate = |person, city, country|
    address = person.address
    { person & address: { address & city: city, country: country } }

add_skill : Employee, Str -> Employee
add_skill = |person, skill|
    if List.contains(person.skills, skill) then
        person
    else
        { person & skills: List.append(person.skills, skill) }

describe : Employee -> Str
describe = |person|
    "${person.name} (${person.dept}, ${person.address.city}) ${Num.to_str(total_pay(person))}"

# ORDERING

by_pay_descending : Employee, Employee -> [LT, EQ, GT]
by_pay_descending = |a, b|
    when Num.compare(total_pay(b), total_pay(a)) is
        EQ -> Num.compare(a.id, b.id)
        other -> other

by_summary : DeptSummary, DeptSummary -> [LT, EQ, GT]
by_summary = |a, b|
    when Num.compare(b.payroll, a.payroll) is
        EQ -> Num.compare(b.headcount, a.headcount)
        other -> other

by_skill_count : SkillCount, SkillCount -> [LT, EQ, GT]
by_skill_count = |a, b|
    when Num.compare(b.count, a.count) is
        EQ -> Num.compare(a.first_seen, b.first_seen)
        other -> other

# GROUPING

group_by_dept : List Employee -> List (Str, List Employee)
group_by_dept = |people|
    List.walk(people, [], add_to_group)
    |> List.map(|(dept, members)| (dept, List.reverse(members)))
    |> List.reverse

add_to_group : List (Str, List Employee), Employee -> List (Str, List Employee)
add_to_group = |groups, person|
    if List.any(groups, |(dept, _)| dept == person.dept) then
        List.map(
            groups,
            |(dept, members)|
                if dept == person.dept then
                    (dept, List.prepend(members, person))
                else
                    (dept, members),
        )
    else
        List.prepend(groups, (person.dept, [person]))

distinct : List Str -> List Str
distinct = |items|
    List.walk(
        items,
        [],
        |seen, item|
            if List.contains(seen, item) then
                seen
            else
                List.append(seen, item),
    )

summarize : (Str, List Employee) -> DeptSummary
summarize = |(dept, members)|
    top =
        List.walk(
            members,
            Err(Empty),
            |best, person|
                when best is
                    Err(Empty) -> Ok(person)
                    Ok(current) ->
                        if total_pay(person) > total_pay(current) then
                            Ok(person)
                        else
                            Ok(current),
        )
    {
        dept,
        headcount: Num.to_i64(List.len(members)),
        payroll: List.sum(List.map(members, total_pay)),
        top_earner:
        when top is
            Ok(person) -> person.name
            Err(Empty) -> "nobody",
        cities: distinct(List.map(members, |person| person.address.city)),
    }

count_skills : List Employee -> List SkillCount
count_skills = |people|
    people
    |> List.join_map(.skills)
    |> List.map_with_index(|skill, index| (Num.to_i64(index), skill))
    |> List.walk([], bump_skill)
    |> List.sort_with(by_skill_count)

bump_skill : List SkillCount, (I64, Str) -> List SkillCount
bump_skill = |counts, (index, skill)|
    if List.any(counts, |entry| entry.skill == skill) then
        List.map(
            counts,
            |entry|
                if entry.skill == skill then
                    { entry & count: entry.count + 1 }
                else
                    entry,
        )
    else
        List.append(counts, { skill, count: 1, first_seen: index })

# REPORTS

show_summary : DeptSummary -> Str
show_summary = |summary|
    "${summary.dept}: ${Num.to_str(summary.headcount)} people, payroll ${Num.to_str(summary.payroll)}, top ${summary.top_earner}, cities ${Str.join_with(summary.cities, "/")}"

show_skill : SkillCount -> Str
show_skill = |entry|
    "${entry.skill} ${Str.repeat("#", Num.to_u64(entry.count))}"

country_totals : List Employee -> List (Str, I64)
country_totals = |people|
    List.walk(
        people,
        [],
        |totals, person|
            if List.any(totals, |(country, _)| country == person.address.country) then
                List.map(
                    totals,
                    |(country, total)|
                        if country == person.address.country then
                            (country, total + total_pay(person))
                        else
                            (country, total),
                )
            else
                List.append(totals, (person.address.country, total_pay(person))),
    )
    |> List.sort_with(|(_, a), (_, b)| Num.compare(b, a))

run : List Str
run =
    active = List.keep_if(employees, .active)
    raised =
        active
        |> List.map(|person| give_raise(person, 10))
        |> List.map(
            |person|
                if person.dept == "Sales" then
                    relocate(person, "Remote", "XX")
                else
                    person,
        )
        |> List.map(|person| add_skill(person, "beni"))
    top =
        raised
        |> List.sort_with(by_pay_descending)
        |> List.take_first(5)
        |> List.map(describe)
    summaries =
        group_by_dept(raised)
        |> List.map(summarize)
        |> List.sort_with(by_summary)
        |> List.map(show_summary)
    skills =
        count_skills(employees)
        |> List.take_first(6)
        |> List.map(show_skill)
    countries =
        country_totals(raised)
        |> List.map(|(country, total)| "${country}=${Num.to_str(total)}")
    payroll = List.sum(List.map(raised, total_pay))
    well_paid = List.len(List.keep_if(raised, |person| total_pay(person) >= 150))
    List.join(
        [
            [
                "active ${Num.to_str(List.len(active))} of ${Num.to_str(List.len(employees))}",
                "payroll ${Num.to_str(payroll)} well-paid ${Num.to_str(well_paid)}",
            ],
            top,
            summaries,
            skills,
            [Str.join_with(countries, " ")],
        ],
    )
