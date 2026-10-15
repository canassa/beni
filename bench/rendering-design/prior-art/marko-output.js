export const $template = "<div><button>Increment</button><output> </output><input><!></div>";
export const $walks = /* next(1), get, over(1), next(1), get, out(1), get, over(1), replace, out(1) */"D bD l b%l";
import { _on, _text, _attr_input_value, _attr_input_value_script, _let, _script, _if, _const, _resumed, _template } from "marko/dom";
const $count = /*@__PURE__*/_let(4, $scope => _text($scope.b, $scope.e * 2));
const $name = /*@__PURE__*/_let(5, $scope => {
  _attr_input_value($scope, "c", $scope.f, $valueChange($scope));
  $name_length($scope, $scope.f?.length);
});
const $setup__script = _script("kaT6IKM", $scope => {
  _on($scope.a, "click", function () {
    $count($scope, +$scope.e + 1);
  });
  _attr_input_value_script($scope, "c");
});
export function $setup($scope) {
  $count($scope, 0);
  $name($scope, "");
  $setup__script($scope);
}
const $if = /*@__PURE__*/_if(3, "<p>Too short</p>");
const $name_length = /*@__PURE__*/_const(6, $scope => $if($scope, $scope.g < 3 ? 0 : 1));
const $valueChange = $scope => _new_name => {
  $name($scope, _new_name);
};
_resumed.g7Wc431 = $valueChange;
export default /*@__PURE__*/_template("FfcJXq4", $template, $walks, $setup);
