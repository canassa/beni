const Direction$turnRight = (dir$1) => {
  switch (dir$1) {
    case "North":
      {
        return "East";
      }
    case "East":
      {
        return "South";
      }
    case "South":
      {
        return "West";
      }
    default:
      {
        return "North";
      }
  }
};
const Direction$turnLeft = (dir$1) => Direction$turnRight(Direction$turnRight(Direction$turnRight(dir$1)));
export { Direction$turnRight, Direction$turnLeft };
//# sourceMappingURL=Direction.mjs.map
