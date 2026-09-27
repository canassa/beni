module Data exposing (run)

-- Records of records, record updates, list pipelines, grouping and sorting
-- over a small employee table.


type alias Address =
    { city : String
    , country : String
    }


type alias Salary =
    { base : Int
    , bonus : Int
    }


type alias Employee =
    { id : Int
    , name : String
    , dept : String
    , address : Address
    , salary : Salary
    , skills : List String
    , active : Bool
    }


type alias DeptSummary =
    { dept : String
    , headcount : Int
    , payroll : Int
    , topEarner : String
    , cities : List String
    }


type alias SkillCount =
    { skill : String
    , count : Int
    , firstSeen : Int
    }


employee : Int -> String -> String -> String -> String -> Int -> Int -> List String -> Bool -> Employee
employee id name dept city country base bonus skills active =
    { id = id
    , name = name
    , dept = dept
    , address = { city = city, country = country }
    , salary = { base = base, bonus = bonus }
    , skills = skills
    , active = active
    }


employees : List Employee
employees =
    [ employee 1 "Ada" "Engineering" "London" "UK" 120 30 [ "zig", "elm", "sql" ] True
    , employee 2 "Grace" "Engineering" "New York" "US" 135 25 [ "cobol", "sql" ] True
    , employee 3 "Linus" "Engineering" "Helsinki" "FI" 110 10 [ "c", "git" ] False
    , employee 4 "Barbara" "Research" "Boston" "US" 140 40 [ "clu", "sql", "elm" ] True
    , employee 5 "Edsger" "Research" "Austin" "US" 125 5 [ "algol", "proofs" ] True
    , employee 6 "Margaret" "Operations" "Boston" "US" 115 20 [ "apollo", "c" ] True
    , employee 7 "Ken" "Operations" "Berkeley" "US" 105 15 [ "c", "unix", "go" ] True
    , employee 8 "Dennis" "Operations" "Berkeley" "US" 105 15 [ "c", "unix" ] False
    , employee 9 "Frances" "Research" "Toronto" "CA" 130 35 [ "fortran", "proofs" ] True
    , employee 10 "Alan" "Research" "Manchester" "UK" 145 0 [ "proofs", "math" ] True
    , employee 11 "Radia" "Engineering" "Seattle" "US" 128 22 [ "networks", "sql" ] True
    , employee 12 "John" "Sales" "London" "UK" 90 60 [ "excel" ] True
    , employee 13 "Hedy" "Sales" "Vienna" "AT" 95 55 [ "radio", "excel" ] True
    , employee 14 "Katherine" "Research" "Hampton" "US" 118 12 [ "math", "fortran" ] True
    , employee 15 "Guido" "Engineering" "Amsterdam" "NL" 122 18 [ "python", "c" ] True
    , employee 16 "Yukihiro" "Engineering" "Matsue" "JP" 119 21 [ "ruby", "c" ] False
    , employee 17 "Anders" "Sales" "Copenhagen" "DK" 88 70 [ "pascal", "excel" ] True
    , employee 18 "Evan" "Engineering" "Copenhagen" "DK" 117 19 [ "elm", "haskell" ] True
    , employee 19 "Rich" "Operations" "Durham" "US" 101 9 [ "lisp", "sql" ] True
    , employee 20 "Joe" "Operations" "Stockholm" "SE" 99 11 [ "erlang", "networks" ] True
    ]



-- SINGLE-RECORD TRANSFORMS


totalPay : Employee -> Int
totalPay person =
    person.salary.base + person.salary.bonus


giveRaise : Int -> Employee -> Employee
giveRaise percent person =
    let
        salary =
            person.salary
    in
    { person | salary = { salary | base = salary.base + salary.base * percent // 100 } }


relocate : String -> String -> Employee -> Employee
relocate city country person =
    let
        address =
            person.address
    in
    { person | address = { address | city = city, country = country } }


addSkill : String -> Employee -> Employee
addSkill skill person =
    if List.member skill person.skills then
        person

    else
        { person | skills = person.skills ++ [ skill ] }


describe : Employee -> String
describe person =
    person.name
        ++ " ("
        ++ person.dept
        ++ ", "
        ++ person.address.city
        ++ ") "
        ++ String.fromInt (totalPay person)



-- ORDERING


byPayDescending : Employee -> Employee -> Order
byPayDescending a b =
    case compare (totalPay b) (totalPay a) of
        EQ ->
            compare a.id b.id

        other ->
            other


bySummary : DeptSummary -> DeptSummary -> Order
bySummary a b =
    case compare b.payroll a.payroll of
        EQ ->
            compare b.headcount a.headcount

        other ->
            other


bySkillCount : SkillCount -> SkillCount -> Order
bySkillCount a b =
    case compare b.count a.count of
        EQ ->
            compare a.firstSeen b.firstSeen

        other ->
            other



-- GROUPING


groupByDept : List Employee -> List ( String, List Employee )
groupByDept people =
    List.foldl addToGroup [] people
        |> List.map (\( dept, members ) -> ( dept, List.reverse members ))
        |> List.reverse


addToGroup : Employee -> List ( String, List Employee ) -> List ( String, List Employee )
addToGroup person groups =
    if List.any (\( dept, _ ) -> dept == person.dept) groups then
        List.map
            (\( dept, members ) ->
                if dept == person.dept then
                    ( dept, person :: members )

                else
                    ( dept, members )
            )
            groups

    else
        ( person.dept, [ person ] ) :: groups


distinct : List String -> List String
distinct items =
    List.foldl
        (\item seen ->
            if List.member item seen then
                seen

            else
                seen ++ [ item ]
        )
        []
        items


summarize : ( String, List Employee ) -> DeptSummary
summarize ( dept, members ) =
    let
        top =
            List.foldl
                (\person best ->
                    case best of
                        Nothing ->
                            Just person

                        Just current ->
                            if totalPay person > totalPay current then
                                Just person

                            else
                                Just current
                )
                Nothing
                members
    in
    { dept = dept
    , headcount = List.length members
    , payroll = List.sum (List.map totalPay members)
    , topEarner =
        case top of
            Just person ->
                person.name

            Nothing ->
                "nobody"
    , cities = distinct (List.map (\person -> person.address.city) members)
    }


countSkills : List Employee -> List SkillCount
countSkills people =
    people
        |> List.concatMap .skills
        |> List.indexedMap (\index skill -> ( index, skill ))
        |> List.foldl bumpSkill []
        |> List.sortWith bySkillCount


bumpSkill : ( Int, String ) -> List SkillCount -> List SkillCount
bumpSkill ( index, skill ) counts =
    if List.any (\entry -> entry.skill == skill) counts then
        List.map
            (\entry ->
                if entry.skill == skill then
                    { entry | count = entry.count + 1 }

                else
                    entry
            )
            counts

    else
        counts ++ [ { skill = skill, count = 1, firstSeen = index } ]



-- REPORTS


showSummary : DeptSummary -> String
showSummary summary =
    summary.dept
        ++ ": "
        ++ String.fromInt summary.headcount
        ++ " people, payroll "
        ++ String.fromInt summary.payroll
        ++ ", top "
        ++ summary.topEarner
        ++ ", cities "
        ++ String.join "/" summary.cities


showSkill : SkillCount -> String
showSkill entry =
    entry.skill ++ " " ++ String.repeat entry.count "#"


countryTotals : List Employee -> List ( String, Int )
countryTotals people =
    List.foldl
        (\person totals ->
            if List.any (\( country, _ ) -> country == person.address.country) totals then
                List.map
                    (\( country, total ) ->
                        if country == person.address.country then
                            ( country, total + totalPay person )

                        else
                            ( country, total )
                    )
                    totals

            else
                totals ++ [ ( person.address.country, totalPay person ) ]
        )
        []
        people
        |> List.sortWith (\( _, a ) ( _, b ) -> compare b a)


run : List String
run =
    let
        active =
            List.filter .active employees

        raised =
            active
                |> List.map (giveRaise 10)
                |> List.map
                    (\person ->
                        if person.dept == "Sales" then
                            relocate "Remote" "XX" person

                        else
                            person
                    )
                |> List.map (addSkill "beni")

        top =
            raised
                |> List.sortWith byPayDescending
                |> List.take 5
                |> List.map describe

        summaries =
            groupByDept raised
                |> List.map summarize
                |> List.sortWith bySummary
                |> List.map showSummary

        skills =
            countSkills employees
                |> List.take 6
                |> List.map showSkill

        countries =
            countryTotals raised
                |> List.map (\( country, total ) -> country ++ "=" ++ String.fromInt total)

        payroll =
            List.sum (List.map totalPay raised)

        wellPaid =
            List.length (List.filter (\person -> totalPay person >= 150) raised)
    in
    [ "active " ++ String.fromInt (List.length active) ++ " of " ++ String.fromInt (List.length employees)
    , "payroll " ++ String.fromInt payroll ++ " well-paid " ++ String.fromInt wellPaid
    ]
        ++ top
        ++ summaries
        ++ skills
        ++ [ String.join " " countries ]
